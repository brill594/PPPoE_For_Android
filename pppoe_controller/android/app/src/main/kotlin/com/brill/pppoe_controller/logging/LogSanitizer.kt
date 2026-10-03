package com.brill.pppoe_controller.logging

object LogSanitizer {
    private val credentialFile = Regex("(?i)pppoe[._-](?:user|pass|cred)|ppp\\.options|(?:pap|chap)-secrets")
    private val authPayload = Regex("(?i)(?:PAP\\s+AuthReq|CHAP\\s+(?:Response|Challenge))")
    // Credential echoes can have malformed quotes or spaces: never retain their tail.
    private val credentials = Regex("""(?i)\b(user(?:name)?|password|passwd|pass|secret|token|authorization|name)(\s*[=:]\s*|\s+).*$""")
    private val urlCredentials = Regex("""(https?://)[^\s/@]+:[^\s/@]+@""")

    fun sanitize(text: String): String = text.lineSequence().joinToString("\n") { line ->
        if (credentialFile.containsMatchIn(line) &&
            (line.contains("printf") || line.contains("echo ") || line.contains("Executing:") || line.trimStart().startsWith("+"))) {
            "[DEBUG] [app] credential command redacted"
        } else {
            val payload = authPayload.find(line)
            if (payload != null) {
                line.substring(0, payload.range.last + 1) + " [REDACTED]"
            } else {
                urlCredentials.replace(credentials.replace(line) { "${it.groupValues[1]}=[REDACTED]" }) {
                    "${it.groupValues[1]}[REDACTED]@"
                }
            }
        }
    }
}
