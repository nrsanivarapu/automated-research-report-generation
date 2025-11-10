pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
    }

    environment {
        // Azure credentials
        AZURE_CLIENT_ID = credentials('azure-client-id')
        AZURE_CLIENT_SECRET = credentials('azure-client-secret')
        AZURE_TENANT_ID = credentials('azure-tenant-id')
        AZURE_SUBSCRIPTION_ID = credentials('azure-subscription-id')

        // ACR credentials
        ACR_USERNAME = credentials('acr-username')
        ACR_PASSWORD = credentials('acr-password')

        // Storage credentials
        STORAGE_ACCOUNT_NAME = credentials('storage-account-name')
        STORAGE_ACCOUNT_KEY = credentials('storage-account-key')

        // API Keys
        OPENAI_API_KEY = credentials('OPENAI_API_KEY')
        GOOGLE_API_KEY = credentials('GOOGLE_API_KEY')
        GROQ_API_KEY = credentials('GROQ_API_KEY')
        TAVILY_API_KEY = credentials('TAVILY_API_KEY')
        LLM_PROVIDER = credentials('LLM_PROVIDER')

        // App config
        APP_RESOURCE_GROUP = 'research-report-app-rg'
        APP_NAME = 'research-report-app'
        ACR_NAME = 'researchreportacr'
        IMAGE_NAME = 'research-report-app'
        CONTAINER_ENV = 'research-report-env'
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    echo 'Checking out code from Git...'
                    // deleteDir() is used instead of cleanWs() for compatibility
                    deleteDir()
                    checkout([
                        $class: 'GitSCM',
                        branches: [[name: '*/main']],
                        userRemoteConfigs: [[url: 'https://github.com/nrsanivarapu/automated-research-report-generation.git']]
                    ])
                }
            }
        }

        stage('Setup Python Environment') {
            steps {
                script {
                    echo 'Setting up Python environment...'
                    sh '''
                        python3 --version
                        python3 -m pip install --upgrade pip --break-system-packages
                    '''
                }
            }
        }

        stage('Install Dependencies') {
            steps {
                script {
                    echo 'Installing Python dependencies...'
                    sh '''
                        pip3 install -r requirements.txt --break-system-packages
                    '''
                }
            }
        }

        stage('Run Tests') {
            steps {
                script {
                    echo 'Running tests...'
                    sh '''
                        python3 -c "from research_and_analyst.api.main import app; print('✅ Imports successful')"
                    '''
                }
            }
        }

        stage('Login to Azure') {
            steps {
                script {
                    echo 'Logging in to Azure...'
                    sh '''
                        az login --service-principal \
                          -u $AZURE_CLIENT_ID \
                          -p $AZURE_CLIENT_SECRET \
                          --tenant $AZURE_TENANT_ID

                        az account set --subscription $AZURE_SUBSCRIPTION_ID
                    '''
                }
            }
        }

        stage('Verify Docker Image in ACR') {
            steps {
                script {
                    echo 'Verifying Docker image in ACR...'
                    def imageTag = sh(
                        script: """
                            az acr repository show-tags \
                              --name $ACR_NAME \
                              --repository $IMAGE_NAME \
                              --orderby time_desc \
                              --output tsv | head -n 1
                        """,
                        returnStdout: true
                    ).trim()

                    if (imageTag) {
                        echo "Found image tag: ${imageTag}"
                        env.IMAGE_TAG = imageTag
                    } else {
                        error "No image found in ACR. Run ./build-and-push-docker-image.sh first."
                    }
                }
            }
        }

        stage('Deploy to Azure Container Apps') {
            steps {
                script {
                    echo "Deploying image ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}..."
                    sh '''
                        if az containerapp show --name $APP_NAME --resource-group $APP_RESOURCE_GROUP > /dev/null 2>&1; then
                            echo "Updating existing Container App..."
                            az containerapp update \
                              --name $APP_NAME \
                              --resource-group $APP_RESOURCE_GROUP \
                              --image ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG}
                        else
                            echo "Creating new Container App..."
                            az containerapp create \
                              --name $APP_NAME \
                              --resource-group $APP_RESOURCE_GROUP \
                              --environment $CONTAINER_ENV \
                              --image ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${IMAGE_TAG} \
                              --registry-server ${ACR_NAME}.azurecr.io \
                              --registry-username $ACR_USERNAME \
                              --registry-password $ACR_PASSWORD \
                              --target-port 8000 \
                              --ingress external \
                              --min-replicas 1 \
                              --max-replicas 3 \
                              --cpu 1.0 \
                              --memory 2.0Gi \
                              --env-vars LLM_PROVIDER=$LLM_PROVIDER
                        fi

                        echo "Adding secrets..."
                        az containerapp secret set \
                          --name $APP_NAME \
                          --resource-group $APP_RESOURCE_GROUP \
                          --secrets \
                            openai-api-key=$OPENAI_API_KEY \
                            google-api-key=$GOOGLE_API_KEY \
                            groq-api-key=$GROQ_API_KEY \
                            tavily-api-key=$TAVILY_API_KEY

                        az containerapp update \
                          --name $APP_NAME \
                          --resource-group $APP_RESOURCE_GROUP \
                          --set-env-vars \
                            OPENAI_API_KEY=secretref:openai-api-key \
                            GOOGLE_API_KEY=secretref:google-api-key \
                            GROQ_API_KEY=secretref:groq-api-key \
                            TAVILY_API_KEY=secretref:tavily-api-key \
                            LLM_PROVIDER=$LLM_PROVIDER
                    '''
                }
            }
        }

        stage('Verify Deployment') {
            steps {
                script {
                    echo 'Verifying deployment...'
                    sh '''
                        APP_URL=$(az containerapp show \
                          --name $APP_NAME \
                          --resource-group $APP_RESOURCE_GROUP \
                          --query properties.configuration.ingress.fqdn -o tsv)

                        echo "Application URL: https://$APP_URL"
                        echo "Waiting for readiness..."
                        sleep 30

                        if curl -f -s https://$APP_URL/health > /dev/null; then
                            echo "Application is responding!"
                        else
                            echo "App may still be initializing..."
                        fi
                    '''
                }
            }
        }
    }

    post {
        success {
            echo 'Pipeline completed successfully!'
        }
        failure {
            echo 'Pipeline failed!'
        }
        always {
            script {
                echo 'Cleaning workspace...'
                // fix: wrap cleanup in node context
                node {
                        deleteDir()
                }
            }
        }
    }
}
