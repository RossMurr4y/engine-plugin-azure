#!groovy
def slackChannel = '#devops-framework'

pipeline {
    options {
        timeout(time: 2, unit: 'HOURS')
    }

    agent {
        label 'hamlet-latest'
    }

    stages {

        stage('Run Azure Template Tests') {
            environment {
                GENERATION_PLUGIN_DIRS = "${WORKSPACE}"
                TEST_OUTPUT_DIR='./hamlet_tests'
            }
            steps {
                sh '''#!/usr/bin/env bash
                    ./test/run_azure_template_tests.sh
                '''
            }

            post {
                always {
                    junit 'hamlet_tests/junit.xml'
                }
            }
        }

        stage('Trigger Docker Build') {
            when {
                branch 'master'
            }

            steps {
                build (
                    job: '../docker-hamlet/master',
                    wait: false
                )
            }
        }
    }

    post {
        failure {
            slackSend (
                message: "*Failure* | <${BUILD_URL}|${JOB_NAME}>",
                channel: "${slackChannel}",
                color: "#D20F2A"
            )
        }
    }
}
