#!/bin/bash

# Azure Deployment Script for Jenkins
# Deploys Jenkins with Python 3.11 and Azure CLI for Research Report Generation CI/CD

set -e

# Configuration
RESOURCE_GROUP="research-report-jenkins-rg"
LOCATION="eastus"
STORAGE_ACCOUNT="reportjenkinsstorens"
FILE_SHARE="jenkins-data"
ACR_NAME="reportjenkinsacrns"
CONTAINER_NAME="jenkins-research-report"
DNS_NAME_LABEL="jenkins-research-$(date +%s | tail -c 6)"
JENKINS_IMAGE_NAME="custom-jenkins"
JENKINS_IMAGE_TAG="lts-git-configured"

# Subscription ID - can be passed as argument or environment variable
SUBSCRIPTION_ID="${1:-${AZURE_SUBSCRIPTION_ID}}"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  Deploying Jenkins for Research Report Generation     ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# Verify Azure login
echo "Verifying Azure login..."
if ! az account show &>/dev/null; then
    echo "Not logged in to Azure. Please run 'az login' first."
    exit 1
fi

# Set subscription if provided
if [ -n "$SUBSCRIPTION_ID" ]; then
    echo "Setting Azure subscription to: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
    if [ $? -ne 0 ]; then
        echo "Failed to set subscription. Please verify the subscription ID."
        exit 1
    fi
else
    echo "ℹ️No subscription ID provided. Using current default subscription."
    CURRENT_SUB=$(az account show --query id -o tsv)
    echo "   Current subscription: $CURRENT_SUB"
fi

# Verify subscription is set correctly
CURRENT_SUB=$(az account show --query id -o tsv)
echo "Using subscription: $CURRENT_SUB"
echo ""

# Store subscription ID for use in commands
if [ -z "$SUBSCRIPTION_ID" ]; then
    SUBSCRIPTION_ID="$CURRENT_SUB"
fi

# Ensure required resource providers are registered (attempt if permitted)
REQUIRED_PROVIDERS=(\
  "Microsoft.Storage" \
  "Microsoft.ContainerRegistry" \
  "Microsoft.ContainerInstance" \
  "Microsoft.OperationalInsights" \
)

echo "Checking required Azure resource providers..."
for provider in "${REQUIRED_PROVIDERS[@]}"; do
  echo " - Verifying provider: $provider"
  regState=$(az provider show --namespace "$provider" --subscription "$SUBSCRIPTION_ID" --query registrationState -o tsv 2>/dev/null || true)
  if [ "$regState" != "Registered" ]; then
    echo "   Provider $provider is not registered (state: ${regState:-Unknown}). Attempting to register..."
    # Allow registration to fail without exiting the script so we can show instructions
    set +e
    az provider register --namespace "$provider" --subscription "$SUBSCRIPTION_ID" --wait
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      echo "   Could not auto-register provider $provider. You may not have permission to register resource providers."
      echo "   Please ask a subscription admin to run: az provider register -n $provider --subscription $SUBSCRIPTION_ID --wait"
    else
      echo "   Successfully requested registration for $provider."
    fi
  else
    echo "   Provider $provider is already registered."
  fi
done

# Create Resource Group
echo "Creating Resource Group: $RESOURCE_GROUP..."
az group create --name $RESOURCE_GROUP --location $LOCATION --subscription "$SUBSCRIPTION_ID"

# Create Storage Account
echo "Creating Storage Account: $STORAGE_ACCOUNT..."
az storage account create \
  --resource-group $RESOURCE_GROUP \
  --name $STORAGE_ACCOUNT \
  --location $LOCATION \
  --sku Standard_LRS \
  --subscription "$SUBSCRIPTION_ID"

# Get Storage Account Key
STORAGE_KEY=$(az storage account keys list \
  --resource-group $RESOURCE_GROUP \
  --account-name $STORAGE_ACCOUNT \
  --subscription "$SUBSCRIPTION_ID" \
  --query '[0].value' -o tsv)

# Create File Share
echo "Creating File Share: $FILE_SHARE..."
az storage share create \
  --name $FILE_SHARE \
  --account-name $STORAGE_ACCOUNT \
  --account-key $STORAGE_KEY \
  --subscription "$SUBSCRIPTION_ID"

# Create Azure Container Registry
echo "Creating Container Registry: $ACR_NAME..."
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Basic \
  --admin-enabled true \
  --subscription "$SUBSCRIPTION_ID"

# Login to ACR
echo "Logging in to Azure Container Registry..."
az acr login --name $ACR_NAME

# Verify ACR exists and admin credentials are available
echo "Verifying ACR provisioning and admin credentials..."
set +e
acr_show=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --subscription "$SUBSCRIPTION_ID" -o json 2>&1)
acr_rc=$?
set -e
if [ $acr_rc -ne 0 ]; then
  echo "Error: Could not find ACR '$ACR_NAME' in resource group '$RESOURCE_GROUP' and subscription '$SUBSCRIPTION_ID'."
  echo "az response:"
  echo "$acr_show"
  echo "Possible causes:"
  echo " - The ACR creation failed or is still provisioning. Check: az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID"
  echo " - Your account does not have permissions to list or read the ACR resource."
  echo " - The subscription context is incorrect. Verify with: az account show"
  echo "Remediation steps you can try now:" 
  echo " 1) Refresh login: az login (or az login --use-device-code)"
  echo " 2) Ensure you are using the correct subscription: az account set --subscription $SUBSCRIPTION_ID"
  echo " 3) If you lack permissions, ask an admin to verify the registry exists and your access."
  echo "Additional diagnostics (copy/paste to run):"
  echo "  az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID"
  echo "  az role assignment list --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
  exit 2
fi

# Check admin credentials access; catch 401-like errors and suggest az login refresh
echo "Checking ACR admin user / permissions..."
set +e
acr_creds=$(az acr credential show --name $ACR_NAME --subscription "$SUBSCRIPTION_ID" -o json 2>&1)
acr_creds_rc=$?
set -e
if [ $acr_creds_rc -ne 0 ]; then
  echo "Failed to retrieve ACR admin credentials. Response:"
  echo "$acr_creds"
  # Detect common 401/permission messages
  if echo "$acr_creds" | grep -qi "401\|Access to registry"; then
    echo "It looks like an authentication/permission issue (401). Try refreshing your Azure login token and retrying:"
    echo "  az logout && az login"
    echo "If you run this in CI (Jenkins), ensure the service principal has 'AcrPush' or 'Contributor' role on the ACR resource or resource group. Example to assign (admin run):"
    echo "  az role assignment create --assignee <sp-object-id-or-appId> --role AcrPush --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
  else
    echo "General error retrieving ACR credentials. Verify registry status and permissions."
  fi
  exit 3
fi


# Build custom Jenkins image with Git and safe.directory configuration
echo "Building custom Jenkins Docker image for Linux AMD64..."
docker build --platform linux/amd64 -f Dockerfile.jenkins -t ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG} .

# Push Jenkins image to ACR with retry logic
echo "Pushing Jenkins image to ACR..."
MAX_RETRIES=3
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if docker push ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG}; then
    echo "Image pushed successfully!"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "Push failed. Retrying ($RETRY_COUNT/$MAX_RETRIES)..."
      sleep 5
    else
      echo "Failed to push image after $MAX_RETRIES attempts."
      echo ""
      echo "This can happen due to network issues or large image size."
      echo ""
      echo "Options to fix:"
      echo "1. Re-run the script (it will use cached layers and be faster)"
      echo "2. Check your internet connection"
      echo "3. Try pushing manually:"
      echo "   az acr login --name $ACR_NAME"
      echo "   docker push ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG}"
      exit 1
    fi
  fi
done

# Get ACR credentials for container deployment
echo "Retrieving ACR credentials..."
ACR_USERNAME=$(az acr credential show \
  --name $ACR_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query username -o tsv)

ACR_PASSWORD=$(az acr credential show \
  --name $ACR_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query passwords[0].value -o tsv)

# Deploy Jenkins Container using custom image
echo "Deploying Jenkins Container..."
az container create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --image ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG} \
  --registry-login-server ${ACR_NAME}.azurecr.io \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --os-type Linux \
  --dns-name-label $DNS_NAME_LABEL \
  --ports 8080 \
  --cpu 2 \
  --memory 4 \
  --azure-file-volume-account-name $STORAGE_ACCOUNT \
  --azure-file-volume-account-key $STORAGE_KEY \
  --azure-file-volume-share-name $FILE_SHARE \
  --azure-file-volume-mount-path //var/jenkins_home \
  --environment-variables JAVA_OPTS="-Djenkins.install.runSetupWizard=true" \
  --subscription "$SUBSCRIPTION_ID"

# Wait for deployment
echo "Waiting for Jenkins to deploy..."
sleep 10

# Get Jenkins URL
JENKINS_URL=$(az container show \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query ipAddress.fqdn -o tsv)

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║           Deployment Complete!                         ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Jenkins URL: http://$JENKINS_URL:8080"
echo ""
echo "Wait 2-3 minutes for Jenkins to fully start, then run:"
echo ""
echo "az container exec \\"
echo "  --resource-group $RESOURCE_GROUP \\"
echo "  --name $CONTAINER_NAME \\"
echo "  --exec-command 'cat /var/jenkins_home/secrets/initialAdminPassword'"
echo ""
echo "Save this information for the next steps!"
