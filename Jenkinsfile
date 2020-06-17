#!groovy

pipeline {
    options {
        timestamps()
        disableConcurrentBuilds()
        quietPeriod(30)
    }

    agent none

    stages {

        stage('Run Azure Template Tests') {
            agent {
                label 'hamlet-latest'
            }
            environment {
                GENERATION_PLUGIN_DIRS = "${WORKSPACE}"
            }
            steps {
                sh '''#!/usr/bin/env bash
                    ./test/run_azure_template_tests.sh
                '''
            }
        }

        stage('Trigger Docker Build') {
            when {
                branch 'master'
                beforeAgent true
            }
            agent none
            steps {
                build (
                    job: '../docker-hamlet/master'
                )
            }
        }
    }
}
