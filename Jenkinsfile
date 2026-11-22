
@Library('slack') _

import io.jenkins.blueocean.rest.impl.pipeline.PipelineNodeGraphVisitor
import io.jenkins.blueocean.rest.impl.pipeline.FlowNodeWrapper
import org.jenkinsci.plugins.workflow.support.steps.build.RunWrapper
import org.jenkinsci.plugins.workflow.actions.ErrorAction

@NonCPS
List<Map> getStageResults(RunWrapper build) {
    def visitor = new PipelineNodeGraphVisitor(build.rawBuild)

    def stages = visitor.pipelineNodes.findAll {
        it.type == FlowNodeWrapper.NodeType.STAGE
    }

    return stages.collect { stage ->
        def errorActions = stage.getPipelineActions(ErrorAction)
        def errors = errorActions?.collect { it.error }.unique()

        return [
            id: stage.id,
            failedStageName: stage.displayName,
            result: "${stage.status.result}",
            errors: errors
        ]
    }
}

@NonCPS
List<Map> getFailedStages(RunWrapper build) {
    return getStageResults(build).findAll {
        it.result == 'FAILURE'
    }
}

pipeline {
    agent any

    environment {
        deploymentName = "devsecops"
        containerName = "devsecops-container"
        serviceName = "devsecops-svc"
        imageName = "henchiahmed/numeric-app:${GIT_COMMIT}"
        applicationURL = "http://192.168.10.111"
        applicationURI = "/increment/99"
    }

    stages {

        stage('Build Artifact - Maven') {
            steps {
                sh "mvn clean package -DskipTests=true"
                archiveArtifacts artifacts: 'target/*.jar'
            }
        }

        stage('Unit Tests - JUnit and JaCoCo') {
            steps {
                sh "mvn test"
            }

            post {
                always {
                    junit(
                        allowEmptyResults: true,
                        testResults: 'target/surefire-reports/*.xml'
                    )

                    jacoco execPattern: 'target/jacoco.exec'
                }
            }
        }

        stage('Mutation Tests - PIT') {
            steps {
                sh "mvn org.pitest:pitest-maven:mutationCoverage"
            }

            post {
                always {
                    pitmutation mutationStatsFile:
                        '**/target/pit-reports/**/mutations.xml'
                }
            }
        }

        stage('SonarQube - SAST') {
            steps {
                withSonarQubeEnv('devsecops') {
                    sh '''
                        mvn org.sonarsource.scanner.maven:sonar-maven-plugin:sonar \
                            -Dsonar.projectKey=devsecops \
                            -Dsonar.host.url=http://192.168.10.111:9000/
                    '''
                }

                timeout(time: 2, unit: 'MINUTES') {
                    script {
                        waitForQualityGate abortPipeline: true
                    }
                }
            }
        }

        stage('Vulnerability Scan - Docker') {
            parallel {

                stage('Dependency Scan') {
                    steps {
                        withCredentials([
                            string(
                                credentialsId: 'nvd-api-key',
                                variable: 'NVD_API_KEY'
                            )
                        ]) {
                            sh '''
                                mvn org.owasp:dependency-check-maven:12.2.2:check \
                                    -DnvdApiKeyEnvironmentVariable=NVD_API_KEY \
                                    -Dformat=ALL
                            '''
                        }
                    }

                    post {
                        always {
                            dependencyCheckPublisher(
                                pattern: '**/target/dependency-check-report.xml',
                                skipNoReportFiles: true
                            )

                            archiveArtifacts(
                                artifacts: '**/target/dependency-check-report.*',
                                allowEmptyArchive: true
                            )
                        }
                    }
                }

                stage('Trivy Scan') {
                    steps {
                        sh 'bash trivy-docker-image-scan.sh'
                    }
                }

                stage('OPA Conftest') {
                    steps {
                        sh '''
                            docker run --rm \
                                -v "$WORKSPACE":/project \
                                -w /project \
                                openpolicyagent/conftest \
                                test --rego-version v0 \
                                --policy opa-docker-security.rego Dockerfile
                        '''
                    }
                }
            }
        }

        stage('Docker Build and Push') {
            steps {
                withDockerRegistry([
                    credentialsId: "docker-hub",
                    url: ""
                ]) {
                    sh 'printenv'
                    sh 'docker build -t henchiahmed/numeric-app:""$GIT_COMMIT"" .'
                    sh 'docker push henchiahmed/numeric-app:""$GIT_COMMIT""'
                }
            }
        }

        stage('Vulnerability Scan - Kubernetes') {
            steps {
                script {
                    parallel(
                        "OPA Scan": {
                            sh '''
                                docker run --rm \
                                    -v "$WORKSPACE":/project \
                                    -w /project \
                                    openpolicyagent/conftest \
                                    test --rego-version v0 \
                                    --policy opa-k8s-security.rego \
                                    k8s_deployment_service.yaml
                            '''
                        },

                        "Kubesec Scan": {
                            sh 'bash kubesec-scan.sh'
                        },

                        "Trivy Scan": {
                            sh 'bash trivy-k8s-scan.sh'
                        }
                    )
                }
            }
        }

        stage('K8S Deployment - DEV') {
            steps {
                withKubeConfig([credentialsId: 'kubeconfig']) {
                    sh '''
                        sed -i "s#replace#${imageName}#g" \
                            k8s_deployment_service.yaml

                        kubectl -n default apply \
                            -f k8s_deployment_service.yaml

                        kubectl -n default rollout status \
                            deployment/devsecops --timeout=180s
                    '''
                }
            }
        }

        stage('Integration Tests - DEV') {
            steps {
                script {
                    try {
                        withKubeConfig([credentialsId: 'kubeconfig']) {
                            sh 'bash integration-test.sh'
                        }
                    } catch (e) {
                        withKubeConfig([credentialsId: 'kubeconfig']) {
                            sh "kubectl -n default rollout undo deployment/${deploymentName}"
                        }
                        throw e
                    }
                }
            }
        }

        stage('OWASP ZAP - DAST') {
            steps {
                withKubeConfig([credentialsId: 'kubeconfig']) {
                    sh 'bash zap.sh'
                }
            }

            post {
                always {
                    archiveArtifacts(
                        artifacts: 'owasp-zap-report/**/*',
                        allowEmptyArchive: true,
                        fingerprint: true
                    )
                }
            }
        }

        stage('Prompte to PROD?') {
            steps {
                timeout(time: 2, unit: 'DAYS') {
                    input 'Do you want to Approve the Deployment to Production Environment/Namespace?'
                }
            }
        }

        stage('K8S CIS Benchmark') {
            steps {
                script {
                    parallel(
                        "Master": {
                            sh 'bash cis-master.sh'
                        },

                        "Etcd": {
                            sh 'bash cis-etcd.sh'
                        },

                        "Kubelet": {
                            sh 'bash cis-kubelet.sh'
                        }
                    )
                }
            }
        }

        stage('K8S Deployment - PROD') {
            steps {
                withKubeConfig([credentialsId: 'kubeconfig']) {
                    sh '''
                        sed -i "s#replace#${imageName}#g" \
                            k8s_PROD-deployment_service.yaml

                        kubectl -n prod apply \
                            -f k8s_PROD-deployment_service.yaml
                    '''

                    sh 'bash k8s-PROD-deployment-rollout-status.sh'
                }
            }
        }

        stage('Integration Tests - PROD') {
            steps {
                script {
                    try {
                        withKubeConfig([credentialsId: 'kubeconfig']) {
                            sh 'bash integration-test-PROD.sh'
                        }
                    } catch (e) {
                        withKubeConfig([credentialsId: 'kubeconfig']) {
                            sh "kubectl -n prod rollout undo deployment/${deploymentName}"
                        }
                        throw e
                    }
                }
            }
        }

        stage('Testing Slack - 1') {
            steps {
                sh 'exit 0'
            }
        }

        stage('Testing Slack - Error Stage') {
            steps {
                sh 'exit 0'
            }
        }

    }

    post {

        always {
            archiveArtifacts(
                artifacts: 'owasp-zap-report/**/*',
                allowEmptyArchive: true
            )

            publishHTML([
                allowMissing: true,
                alwaysLinkToLastBuild: true,
                keepAll: true,
                reportDir: 'owasp-zap-report',
                reportFiles: 'zap_report.html',
                reportName: 'OWASP ZAP HTML Report',
                reportTitles: 'OWASP ZAP HTML Report'
            ])
        }

        success {
            script {
                env.failedStage = "none"
                env.emoji = ":white_check_mark: :tada: :thumbsup_all:"

                sendNotification currentBuild.result
            }
        }

        failure {
            script {
                def failedStages = getFailedStages(currentBuild)

                env.failedStage = failedStages ?
                    failedStages[0].failedStageName : "unknown"

                env.emoji = ":x: :red_circle: :sos:"

                sendNotification currentBuild.result
            }
        }

        aborted {
            script {
                env.failedStage = "Pipeline aborted"
                env.emoji = ":warning:"

                sendNotification currentBuild.result
            }
        }
    }
}
