package io.github.legendarymsr.flip4lab

import java.io.InputStream

/**
 * Minimal root shell: one `su` process per command, script passed with -c,
 * stdout+stderr merged and streamed line by line. KernelSU's su takes
 * --mount-master to run in init's mount namespace (needed to see other
 * apps' /data/data, e.g. Termux's home); fall back to plain su.
 */
object RootShell {
    @Volatile var mountMaster = true
    @Volatile var current: Process? = null
    @Volatile private var cancelled = false

    private fun argv(script: String) =
        if (mountMaster) listOf("su", "--mount-master", "-c", script) else listOf("su", "-c", script)

    /** Runs [script] as root. Returns the exit code, or -1 if su couldn't start. */
    fun run(script: String, stdin: InputStream? = null, onLine: (String) -> Unit): Int {
        val p = try {
            ProcessBuilder(argv(script)).redirectErrorStream(true).start()
        } catch (e: Exception) {
            onLine("su: ${e.message}")
            return -1
        }
        current = p
        cancelled = false
        val feeder = Thread {
            try {
                p.outputStream.use { os -> stdin?.use { it.copyTo(os, 1 shl 16) } }
            } catch (_: Exception) { }
        }.apply { start() }
        try {
            p.inputStream.bufferedReader().useLines { lines -> lines.forEach(onLine) }
        } catch (_: Exception) { }
        if (cancelled) { current = null; return -2 } // root child can't be killed; it dies on SIGPIPE
        feeder.join()
        val rc = p.waitFor()
        current = null
        return rc
    }

    fun capture(script: String): Pair<Int, String> {
        val sb = StringBuilder()
        val rc = run(script) { sb.append(it).append('\n') }
        return rc to sb.toString()
    }

    /** Detect root; also probes whether --mount-master is understood. */
    fun probe(): Boolean {
        mountMaster = true
        if (capture("id -u").second.trim() == "0") return true
        mountMaster = false
        return capture("id -u").second.trim() == "0"
    }

    /** Stop reading the current command (we can't kill a root process from the app). */
    fun cancel() {
        val p = current ?: return
        cancelled = true
        try { p.inputStream.close() } catch (_: Exception) { }
        p.destroy()
    }
}
