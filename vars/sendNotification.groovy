
def call(String buildStatus = 'STARTED') {

    buildStatus = buildStatus ?: 'SUCCESS'

    def color
    def emoji

    if (buildStatus == 'SUCCESS') {
        color = '#47ec05'
        emoji = ':white_check_mark:'
    } else if (buildStatus == 'UNSTABLE') {
        color = '#d5ee0d'
        emoji = ':warning:'
    } else {
        color = '#ec2805'
        emoji = ':x:'
    }

    def deployment = env.deploymentName ?: 'devsecops'
    def appUrl = env.applicationURL ?: 'http://192.168.10.111'
    def jobName = env.JOB_NAME ?: 'Unknown'
    def buildNumber = env.BUILD_NUMBER ?: 'N/A'
    def buildUrl = env.BUILD_URL ?: ''
    def failedStage = env.failedStage ?: 'none'

    def gitCommit = env.GIT_COMMIT ?: 'N/A'
    def previousCommit = env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: 'N/A'
    def gitBranch = env.GIT_BRANCH ?: 'main'
    def gitUrl = env.GIT_URL ?: 'https://github.com/HenchiAhmed/devsecops'

    // Message texte compatible avec Jenkins Slack Plugin
    def msg = """
${emoji} *K8S Deployment - ${deployment}*

*Pipeline Status:* ${buildStatus}
*Job Name:* ${jobName}
*Build Number:* #${buildNumber}
*Failed Stage:* ${failedStage}

*Deployment:* ${deployment}
*Application:* ${appUrl}
*Git Branch:* ${gitBranch}
*Git Commit:* ${gitCommit}
*Previous Successful Commit:* ${previousCommit}

*Jenkins Build:* ${buildUrl}
*GitHub Repository:* ${gitUrl}
""".stripIndent().trim()

    // Notification Slack
    slackSend(
        color: color,
        message: msg,
        failOnError: false
    )
}
