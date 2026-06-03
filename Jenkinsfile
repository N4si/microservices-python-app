pipeline {
    agent any

    environment {
        DOCKERHUB    = credentials('dockerhub-credentials')
        AWS_CREDS    = credentials('aws-credentials')
        CLUSTER      = 'vidcast-cluster'
        REGION       = 'eu-west-2'
        BUILD_TAG    = "${env.BUILD_NUMBER}-${env.GIT_COMMIT?.take(7) ?: 'unknown'}"
        STAGING_IP   = credentials('swarm-staging-ip')
    }

    stages {
        stage('Checkout') {
            steps {
                git branch: 'main', url: 'https://github.com/johnbaabalola/microservices-python-app.git'
            }
        }

        stage('Lint') {
            steps {
                sh 'pip install ruff && ruff check src/ --exclude src/frontend'
            }
        }

        stage('Build Images') {
            parallel {
                stage('Build Auth') {
                    steps {
                        sh "docker build -t vidcast/auth:${BUILD_TAG} src/auth-service/"
                    }
                }
                stage('Build Gateway') {
                    steps {
                        sh "docker build -t vidcast/gateway:${BUILD_TAG} src/gateway-service/"
                    }
                }
                stage('Build Converter') {
                    steps {
                        sh "docker build -t vidcast/converter:${BUILD_TAG} src/converter-service/"
                    }
                }
                stage('Build Notification') {
                    steps {
                        sh "docker build -t vidcast/notification:${BUILD_TAG} src/notification-service/"
                    }
                }
            }
        }

        stage('Security Scan') {
            steps {
                sh """
                    for svc in auth gateway converter notification; do
                        trivy image --severity CRITICAL,HIGH --exit-code 1 \
                          --ignore-unfixed vidcast/\${svc}:${BUILD_TAG}
                    done
                """
            }
        }

        stage('Push Images') {
            steps {
                sh "echo \$DOCKERHUB_PSW | docker login -u \$DOCKERHUB_USR --password-stdin"
                sh """
                    for svc in auth gateway converter notification; do
                        docker push vidcast/\${svc}:${BUILD_TAG}
                    done
                """
            }
        }

        stage('Deploy Staging (Swarm)') {
            steps {
                sh """
                    ssh -o StrictHostKeyChecking=no ubuntu@${STAGING_IP} \
                      'docker stack deploy -c docker-compose.swarm.yml vidcast'
                """
                sh 'sleep 30'
            }
        }

        stage('Smoke Test Staging') {
            steps {
                sh "curl -f http://${STAGING_IP}:8080/healthz || exit 1"
            }
        }

        stage('Approve Production') {
            steps {
                input message: 'Staging tests passed. Deploy to Production?', ok: 'Deploy to Production'
            }
        }

        stage('Deploy Production (EKS)') {
            steps {
                sh """
                    aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}
                    for svc in auth gateway converter notification; do
                        kubectl set image deployment/\${svc} \${svc}=vidcast/\${svc}:${BUILD_TAG}
                        kubectl rollout status deployment/\${svc} --timeout=120s
                    done
                """
            }
        }
    }

    post {
        failure {
            sh """
                aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION} || true
                for svc in auth gateway converter notification; do
                    kubectl rollout undo deployment/\${svc} || true
                done
            """
            echo "PIPELINE FAILED — automatic rollback executed for all services"
        }
        success {
            echo "Pipeline completed — build ${BUILD_TAG} deployed to production"
        }
    }
}
