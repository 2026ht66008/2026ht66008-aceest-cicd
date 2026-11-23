// ACEest Fitness & Gym - CI/CD pipeline (Assignment 2)
//
// Every push to main: test -> SonarQube -> Docker image -> Docker Hub -> rolling update on Minikube.
// "Build with Parameters" adds: images for every version, the other deployment strategies,
// and a deliberately bad release to show the automatic rollback.

pipeline {
    agent any

    // Check GitHub for new commits every 2 minutes
    triggers {
        pollSCM('H/2 * * * *')
    }

    parameters {
        booleanParam(name: 'BUILD_ALL_VERSIONS', defaultValue: false,
                     description: 'Build, test and push an image for every version tag (v1.0 ... v3.2.4)')
        choice(name: 'DEPLOY', choices: ['rolling', 'all-strategies', 'none'],
               description: 'rolling = rolling update only. all-strategies = rolling, blue-green, canary, A/B and shadow')
        string(name: 'STABLE_VERSION', defaultValue: 'v3.1.2',
               description: 'Version kept on the "old" side: canary stable, A/B group A, shadow live')
        booleanParam(name: 'SIMULATE_BAD_RELEASE', defaultValue: false,
                     description: 'Deploy an image tag that does not exist, to show the automatic rollback')
    }

    environment {
        // Your Docker Hub repository (the username is set once with sed, see the guide)
        IMAGE = '2026ht66008/aceest-fitness'
    }

    stages {
        stage('Checkout') {
            steps {
                deleteDir()            // start from an empty workspace for a clean build
                checkout scm
                sh 'git fetch --tags --force'
                script {
                    // e.g. APP_VERSION = "3.2.4" in ACEest_Fitness.py -> v3.2.4
                    env.VERSION = 'v' + sh(returnStdout: true,
                        script: "grep -m1 '^APP_VERSION' ACEest_Fitness.py | cut -d'\"' -f2").trim()
                }
                echo "Building ACEest ${env.VERSION}"
            }
        }

        stage('Build') {
            steps {
                sh '''
                    python3 -m venv venv
                    venv/bin/pip install -q -r requirements.txt pytest-cov
                '''
            }
        }

        stage('Unit Tests') {
            steps {
                sh 'venv/bin/python -m pytest -v --junitxml=test-results.xml --cov=ACEest_Fitness --cov-report=xml:coverage.xml'
            }
            post {
                always {
                    junit 'test-results.xml'
                }
            }
        }

        stage('SonarQube Quality Gate') {
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh '''
                        /opt/sonar-scanner/bin/sonar-scanner \
                          -Dsonar.host.url=http://localhost:9000 \
                          -Dsonar.token=$SONAR_TOKEN \
                          -Dsonar.qualitygate.wait=true
                        venv/bin/python scripts/sonar_report.py
                    '''
                }
            }
        }

        stage('Docker Build') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub',
                                                  usernameVariable: 'DOCKERHUB_USERNAME',
                                                  passwordVariable: 'DOCKERHUB_TOKEN')]) {
                    sh '''
                        echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin
                        docker build -t $IMAGE:$VERSION -t $IMAGE:latest .
                    '''
                }
            }
        }

        stage('Test in Container') {
            steps {
                sh 'docker run --rm $IMAGE:$VERSION python -m pytest -q -p no:cacheprovider'
            }
        }

        stage('Push to Docker Hub') {
            steps {
                sh '''
                    docker push $IMAGE:$VERSION
                    docker push $IMAGE:latest
                '''
            }
        }

        stage('Build All Versions') {
            when { expression { params.BUILD_ALL_VERSIONS } }
            steps {
                sh 'bash scripts/build-all-versions.sh $IMAGE'
            }
        }

        stage('Archive Artifacts') {
            steps {
                sh '''
                    mkdir -p dist
                    git archive --format=tar.gz --prefix=aceest-fitness-$VERSION/ -o dist/aceest-fitness-$VERSION.tar.gz HEAD
                    docker image ls $IMAGE > dist/docker-images.txt
                '''
                archiveArtifacts artifacts: 'dist/*, test-results.xml, coverage.xml, reports/*', fingerprint: true
            }
        }

        stage('Deploy: Rolling Update') {
            when { expression { params.DEPLOY == 'rolling' || params.DEPLOY == 'all-strategies' } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'dockerhub',
                                                  usernameVariable: 'DOCKERHUB_USERNAME',
                                                  passwordVariable: 'DOCKERHUB_TOKEN')]) {
                    sh 'bash k8s/deploy.sh init'
                }
                sh 'bash k8s/deploy.sh rolling $VERSION'
            }
        }

        stage('Deploy: Blue-Green') {
            when { expression { params.DEPLOY == 'all-strategies' } }
            steps {
                sh 'bash k8s/deploy.sh bluegreen $VERSION'
            }
        }

        stage('Deploy: Canary') {
            when { expression { params.DEPLOY == 'all-strategies' } }
            steps {
                sh 'bash k8s/deploy.sh canary $STABLE_VERSION $VERSION'
            }
        }

        stage('Deploy: A/B Testing') {
            when { expression { params.DEPLOY == 'all-strategies' } }
            steps {
                sh 'bash k8s/deploy.sh ab $STABLE_VERSION $VERSION'
            }
        }

        stage('Deploy: Shadow') {
            when { expression { params.DEPLOY == 'all-strategies' } }
            steps {
                sh 'bash k8s/deploy.sh shadow $STABLE_VERSION $VERSION'
                sh 'bash k8s/deploy.sh status'
            }
        }

        stage('Rollback Demo') {
            when { expression { params.SIMULATE_BAD_RELEASE } }
            steps {
                // This stage is expected to fail: the bad version never becomes ready,
                // so deploy.sh rolls the deployment back and exits with an error.
                sh 'bash k8s/deploy.sh rolling v0.0.0-does-not-exist'
            }
        }
    }

    post {
        always {
            sh 'docker logout || true'
        }
        success {
            echo "Done - ${env.IMAGE}:${env.VERSION} was tested, pushed to Docker Hub and deployed"
        }
        failure {
            echo 'Pipeline failed - stages after the failure were skipped, and a failed deploy was rolled back'
        }
    }
}
