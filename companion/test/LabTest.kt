@file:JvmName("LabTest")

import io.github.legendarymsr.flip4lab.*

// Plain-JVM tests for the shell/parse logic (no JUnit dependency).
var failed = 0
fun check(name: String, ok: Boolean) { println((if (ok) "ok   " else "FAIL ") + name); if (!ok) failed++ }

fun sh(script: String, stdin: String = ""): Pair<Int, String> {
    val p = ProcessBuilder("sh", "-c", script).redirectErrorStream(true).start()
    p.outputStream.use { it.write(stdin.toByteArray()) }
    val out = p.inputStream.bufferedReader().readText()
    return p.waitFor() to out
}

fun main() {
    // quoting survives a real shell
    for (s in listOf("plain", "with space", "it's", "\$(rm -rf /)", "a\"b\\c", "`x`;|&")) {
        check("shQuote round-trip: $s", sh("printf %s ${shQuote(s)}").second == s)
    }
    check("nixroot args quoted", Scripts.nixroot("bash", "-lc", "echo 'hi'") ==
        "sh /data/adb/modules/nixchroot/nixroot 'bash' '-lc' 'echo '\\''hi'\\'''")
    check("bootstrap args", Scripts.bootstrapArgs(false, null) == listOf("--bootstrap"))
    check("bootstrap args force+file", Scripts.bootstrapArgs(true, "/x y") == listOf("--bootstrap", "--force", "--file", "/x y"))
    check("installModule", Scripts.installModule("/data/user/0/p/cache/nixchroot.zip") ==
        "/data/adb/ksud module install '/data/user/0/p/cache/nixchroot.zip'")

    // every script parses as POSIX sh
    for ((n, s) in listOf("status" to Scripts.status, "detached" to Scripts.detached(Scripts.nixroot("--bootstrap")),
        "termux" to Scripts.enableTermuxExternal, "mitmFromChroot" to Scripts.mitmFromChroot,
        "receiveFile" to Scripts.receiveFile("/tmp/a b/c"), "tailJob" to Scripts.tailJob)) {
        val (rc, out) = sh("sh -n -c ${shQuote(s)}")
        check("sh -n $n", rc == 0 && out.isEmpty())
    }

    // status script runs on a non-Android box and yields parseable output
    val st = Status.parse(sh(Scripts.status).second)
    check("status has module key", st.kv["module"] == "none")
    check("status rootfs=0 on box", !st.rootfs)
    check("status mounts numeric", st.kv["mounts"]?.toIntOrNull() != null)

    // detached job: runs, logs, writes exit marker
    val tmp = kotlin.io.path.createTempDirectory("flip4lab").toFile()
    val d = Scripts.detached("echo hello; exit 7").replace("/data/local/tmp", tmp.path).replace("/sys/", "${tmp.path}/sys/")
    sh(d); Thread.sleep(1500)
    val log = java.io.File(tmp, "flip4lab-job.log").readText()
    check("detached logs output", log.contains("hello"))
    check("detached exit marker", log.lines().mapNotNull(ProgressParser::exitCode).singleOrNull() == 7)
    check("detached removes pidfile", !java.io.File(tmp, "flip4lab-job.pid").exists())
    val (trc, tout) = sh(Scripts.tailJob.replace("/data/local/tmp", tmp.path))
    check("tailJob replays log and stops at marker", trc == 0 && tout.contains("hello") && tout.trim().endsWith("FLIP4LAB_JOB_EXIT=7"))
    java.io.File(tmp, "flip4lab-job.log").writeText("partial line\n")
    val (_, dout) = sh(Scripts.tailJob.replace("/data/local/tmp", tmp.path))
    check("tailJob synthesises marker for a dead job", dout.trim().endsWith("FLIP4LAB_JOB_EXIT=137"))

    // receiveFile writes stdin atomically
    val dest = "${tmp.path}/dl dir/f.bin"
    check("receiveFile rc", sh(Scripts.receiveFile(dest), "payload").first == 0)
    check("receiveFile content", java.io.File(dest).readText() == "payload")
    tmp.deleteRecursively()

    // Status.next decision table
    fun s(vararg kv: Pair<String, String>) = Status(kv.toMap())
    check("next: no root", s().next.startsWith("Grant root"))
    check("next: install", s("uid" to "0", "ksud" to "1", "module" to "none").next == "Tap Install module.")
    check("next: reboot", s("uid" to "0", "ksud" to "1", "module" to "pending").next.startsWith("Reboot"))
    check("next: setup", s("uid" to "0", "ksud" to "1", "module" to "installed", "rootfs" to "0").next.startsWith("Tap Set up (downloads"))
    check("next: resume", s("uid" to "0", "ksud" to "1", "module" to "installed", "rootfs" to "0", "partial" to "5").next.contains("resume"))
    check("next: mount", s("uid" to "0", "ksud" to "1", "module" to "installed", "rootfs" to "1", "mounts" to "0").next.startsWith("Tap Mount"))
    check("next: ready", s("uid" to "0", "ksud" to "1", "module" to "installed", "rootfs" to "1", "mounts" to "9").next.startsWith("Ready"))

    // progress lines exactly as bootstrap.sh prints them
    check("progress download", ProgressParser.parse("  ... 123 / 1231 MiB (9%)") == Progress("download", 9, "Downloading 123 / 1231 MiB"))
    check("progress extract", ProgressParser.parse("  extract: 40 / 522 store paths (7%)")?.percent == 7)
    check("progress verify", ProgressParser.parse("verifying sha256 of /x (takes ~30 s) ...")?.phase == "verify")
    check("progress done", ProgressParser.parse("done. Enter with:  su -c nixroot")?.percent == 100)
    check("progress none", ProgressParser.parse("downloader: bundled curl") == null)
    check("exit marker", ProgressParser.exitCode("FLIP4LAB_JOB_EXIT=0") == 0 && ProgressParser.exitCode("x") == null)

    if (failed > 0) { println("$failed FAILED"); kotlin.system.exitProcess(1) }
    println("all passed")
}
