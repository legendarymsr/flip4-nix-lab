package io.github.legendarymsr.flip4lab

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.text.InputType
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private val ui = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var busy = false
    @Volatile private var tailing = false
    private var rootChecked = false
    private var st = Status(emptyMap())

    private lateinit var statusText: TextView
    private lateinit var nextText: TextView
    private lateinit var progress: ProgressBar
    private lateinit var progressText: TextView
    private lateinit var logText: TextView
    private lateinit var scroll: ScrollView
    private lateinit var withMitm: CheckBox
    private lateinit var cmdEdit: EditText
    private val buttons = mutableMapOf<String, Button>()
    private val logLines = ArrayDeque<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dp = resources.displayMetrics.density
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val p = (12 * dp).toInt(); setPadding(p, p, p, p)
        }
        fun section(t: String) = col.addView(TextView(this).apply {
            text = t; textSize = 13f; setTypeface(typeface, Typeface.BOLD)
            setPadding(0, (14 * dp).toInt(), 0, (4 * dp).toInt())
        })
        fun row(vararg bs: Pair<String, () -> Unit>) = col.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            bs.forEach { (label, action) ->
                addView(Button(this@MainActivity).apply {
                    text = label; isAllCaps = false
                    setOnClickListener { action() }
                    buttons[label] = this
                }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            }
        })

        col.addView(TextView(this).apply { text = "Flip4 Nix Lab"; textSize = 22f })
        nextText = TextView(this).apply { textSize = 16f; setPadding(0, (6 * dp).toInt(), 0, 0) }
        col.addView(nextText)
        statusText = TextView(this).apply { typeface = Typeface.MONOSPACE; textSize = 12f }
        col.addView(statusText)
        row("Refresh" to { refresh() })

        section("1 · KernelSU module")
        withMitm = CheckBox(this).apply { text = "also install mitm-cacert (system CA injection)" }
        col.addView(withMitm)
        row("Install module" to { installModules() }, "Reboot" to { confirmReboot() })

        section("2 · Nix rootfs")
        row("Set up" to { setup(force = false) }, "Use local tarball…" to { pick(REQ_TARBALL, "*/*") })
        row("Mount" to { simple(Scripts.nixroot("--mount")) }, "Unmount" to { simple(Scripts.nixroot("--umount")) },
            "Reinstall" to { confirmForce() })
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply { max = 100; visibility = View.GONE }
        col.addView(progress)
        progressText = TextView(this).apply { textSize = 12f }
        col.addView(progressText)

        section("3 · Shell")
        row("Open shell (Termux)" to { openTermux() }, "Allow Termux ext. apps" to { enableTermuxThenOpen(open = false) })
        cmdEdit = EditText(this).apply {
            hint = "command to run in the chroot, e.g. nix --version"
            typeface = Typeface.MONOSPACE; textSize = 13f
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            isSingleLine = true
        }
        col.addView(cmdEdit)
        row("Run in chroot" to { runInChroot() }, "Status" to { simple(Scripts.nixroot("--status")) })

        section("4 · mitmproxy CA (optional)")
        row("Pick CA file…" to { pick(REQ_CA, "*/*") }, "Use chroot's mitmproxy CA" to { mitm(null) })

        section("Log")
        logText = TextView(this).apply { typeface = Typeface.MONOSPACE; textSize = 11f; setTextIsSelectable(true) }
        col.addView(logText)
        row("Clear log" to { logLines.clear(); logText.text = "" }, "Stop following" to { RootShell.cancel() })

        scroll = ScrollView(this).apply { addView(col) }
        scroll.setOnApplyWindowInsetsListener { v, insets ->
            val b = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
            v.setPadding(b.left, b.top, b.right, b.bottom); insets
        }
        setContentView(scroll)
        render()
        refresh()
    }

    override fun onResume() { super.onResume(); if (rootChecked && !busy) refresh() }

    // ---- plumbing ---------------------------------------------------------

    private fun log(line: String) = ui.post {
        logLines.addLast(line); while (logLines.size > 3000) logLines.removeFirst()
        logText.text = logLines.joinToString("\n")
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun bg(task: () -> Unit) {
        if (busy) { toastLog("busy, wait for the current step"); return }
        busy = true; render()
        worker.execute {
            try { task() } catch (e: Exception) { log("error: $e") }
            busy = false
            loadStatus()
        }
    }

    private fun toastLog(s: String) = log("· $s")

    private fun loadStatus() {
        if (!rootChecked) { RootShell.probe(); rootChecked = true }
        val (_, out) = RootShell.capture(Scripts.status)
        st = Status.parse(out)
        ui.post { render() }
        if (st.jobRunning && !tailing) worker.execute { follow() }
    }

    private fun refresh() { if (!busy) worker.execute { loadStatus() } }

    private fun render() {
        nextText.text = if (busy) "Working…" else st.next
        statusText.text = buildString {
            append("root ${yn(st.root)}  ksud ${yn(st.ksud)} ${st.kv["ksud_version"] ?: ""}\n")
            append("nixchroot ${st.module} ${st.kv["module_version"] ?: ""}   mitm-cacert ${st.mitm}\n")
            append("rootfs ${yn(st.rootfs)} at ${st.nixroot}   mounts ${st.mounts}")
            if (st.partialBytes > 0) append("\npartial download ${st.partialBytes / 1048576} MiB (resumable)")
            if (st.termux) append("\ntermux yes, external apps ${yn(st.termuxExternal)}")
        }
        val ok = st.root && !busy && !st.jobRunning
        val usable = ok && st.moduleUsable
        mapOf(
            "Install module" to (ok && st.ksud), "Reboot" to st.root,
            "Set up" to (usable && !st.rootfs), "Use local tarball…" to usable,
            "Mount" to (usable && st.rootfs), "Unmount" to (usable && st.mounted), "Reinstall" to (usable && st.rootfs),
            "Open shell (Termux)" to (st.rootfs && st.termux), "Allow Termux ext. apps" to (ok && st.termux),
            "Run in chroot" to (usable && st.rootfs), "Status" to usable,
            "Pick CA file…" to (usable && st.rootfs && st.mitm == "installed"),
            "Use chroot's mitmproxy CA" to (usable && st.rootfs && st.mitm == "installed"),
        ).forEach { (k, v) -> buttons[k]?.isEnabled = v }
        window.apply {
            if (busy || st.jobRunning) addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun yn(b: Boolean) = if (b) "yes" else "no"

    private fun simple(script: String) = bg {
        log("$ ${script.lineSequence().first()}")
        val rc = RootShell.run(script, onLine = ::log)
        log("exit $rc")
    }

    private fun setProgress(p: Progress?) = ui.post {
        if (p == null) { progress.visibility = View.GONE; progressText.text = ""; return@post }
        progress.visibility = View.VISIBLE
        progress.isIndeterminate = p.percent < 0
        if (p.percent >= 0) progress.progress = p.percent
        progressText.text = p.text
    }

    // ---- actions ------------------------------------------------------------

    private fun installModules() = bg {
        val zips = buildList {
            add("nixchroot.zip"); if (withMitm.isChecked) add("mitm-cacert.zip")
        }
        for (z in zips) {
            val f = File(cacheDir, z)
            assets.open(z).use { i -> f.outputStream().use { i.copyTo(it) } }
            log("$ ksud module install $z")
            val rc = RootShell.run(Scripts.installModule(f.absolutePath), onLine = ::log)
            f.delete()
            log("exit $rc")
            if (rc != 0) { log("install failed"); return@bg }
        }
        ui.post { confirmReboot("Module installed. Reboot now to activate it?") }
    }

    private fun confirmReboot(msg: String = "Reboot the phone now?") {
        AlertDialog.Builder(this).setMessage(msg)
            .setPositiveButton("Reboot") { _, _ -> worker.execute { RootShell.run(Scripts.REBOOT) { log(it) } } }
            .setNegativeButton("Later", null).show()
    }

    private fun confirmForce() {
        AlertDialog.Builder(this)
            .setMessage("Reinstall the rootfs? Unmounts the chroot, re-downloads (~1.2 GiB) and extracts over it. ${st.nixroot}/etc is backed up first; your files elsewhere in the chroot stay.")
            .setPositiveButton("Reinstall") { _, _ -> setup(force = true) }
            .setNegativeButton("Cancel", null).show()
    }

    private fun setup(force: Boolean, file: String? = null) = bg { startJob(force, file) }

    private fun startJob(force: Boolean, file: String?) {
        val inner = Scripts.nixroot(*Scripts.bootstrapArgs(force, file).toTypedArray())
        log("$ $inner  (detached; safe to leave the app)")
        RootShell.run(Scripts.detached(inner), onLine = ::log)
        Thread.sleep(500)
        follow()
    }

    /** Tail the detached job's log until its exit marker. */
    private fun follow() {
        if (tailing) return
        tailing = true
        var exit: Int? = null
        try {
            RootShell.run(Scripts.tailJob) { line ->
                ProgressParser.exitCode(line)?.let { exit = it; return@run }
                log(line)
                ProgressParser.parse(line)?.let { setProgress(it) }
            }
        } finally { tailing = false }
        when (exit) {
            null -> log("· stopped following (job may still be running; Refresh to re-attach)")
            0 -> { setProgress(Progress("done", 100, "Done. Tap Open shell.")); log("· setup finished") }
            else -> { setProgress(null); log("· setup failed (exit $exit). Tap Set up again to resume.") }
        }
        loadStatus()
    }

    private fun runInChroot() {
        Scripts.chrootCommand(cmdEdit.text.toString()).fold(
            onSuccess = { simple(it) },
            onFailure = { toastLog(it.message ?: "bad command") },
        )
    }

    private fun openTermux() {
        if (!st.termuxExternal) {
            AlertDialog.Builder(this)
                .setMessage("Termux has to allow commands from other apps (allow-external-apps = true in ~/.termux/termux.properties). Set it now via root? Termux is restarted once.")
                .setPositiveButton("Set it") { _, _ -> enableTermuxThenOpen() }
                .setNegativeButton("Cancel", null).show()
            return
        }
        if (checkSelfPermission(TERMUX_PERM) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(TERMUX_PERM), REQ_PERM); return
        }
        launchTermux()
    }

    private fun enableTermuxThenOpen(open: Boolean = true) = bg {
        var changed = false
        val rc = RootShell.run(Scripts.enableTermuxExternal) { l ->
            if (l == "TERMUX_EXT=changed") changed = true else log(l)
        }
        if (rc == 0 && open) ui.postDelayed({ loadStatusThen { openTermux() } }, if (changed) 800L else 0L)
    }

    private fun loadStatusThen(next: () -> Unit) = worker.execute { loadStatus(); ui.post(next) }

    /**
     * Ask Termux's RunCommandService for a new foreground session running
     * `su -c nixroot`. It must be started with startForegroundService (Termux
     * is usually not running, so a plain startService is a background start
     * and Android 8+ refuses it); we call it while we're the visible app, and
     * RunCommandService calls startForeground itself and brings the terminal
     * to the front (BACKGROUND=false, SESSION_ACTION=0). If the platform still
     * refuses, root's `am` starts TermuxActivity and then the service.
     */
    private fun launchTermux() {
        val i = Intent("com.termux.RUN_COMMAND")
            .setClassName("com.termux", "com.termux.app.RunCommandService")
            .putExtra("com.termux.RUN_COMMAND_PATH", "/system/bin/su")
            .putExtra("com.termux.RUN_COMMAND_ARGUMENTS", Scripts.termuxShellArgs.toTypedArray())
            .putExtra("com.termux.RUN_COMMAND_BACKGROUND", false)
            .putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
        try {
            startForegroundService(i)
            log("· opened a Termux session: su -c nixroot")
        } catch (e: Exception) {
            log("Termux: ${e.javaClass.simpleName}; retrying via root am")
            simple(Scripts.termuxViaRoot)
        }
    }

    override fun onRequestPermissionsResult(rc: Int, perms: Array<out String>, res: IntArray) {
        if (rc == REQ_PERM) {
            if (res.firstOrNull() == PackageManager.PERMISSION_GRANTED) launchTermux()
            else log("· Termux RUN_COMMAND permission denied (App info → Permissions → Additional permissions)")
        }
    }

    @Deprecated("platform API; no AndroidX on purpose")
    private fun pick(req: Int, mime: String) {
        @Suppress("DEPRECATION")
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(mime), req)
    }

    @Deprecated("platform API; no AndroidX on purpose")
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        @Suppress("DEPRECATION") super.onActivityResult(req, res, data)
        val uri = data?.data ?: return
        if (res != RESULT_OK) return
        when (req) {
            REQ_TARBALL -> localTarball(uri)
            REQ_CA -> mitm(uri)
        }
    }

    /** Stream the picked file to root (no extra copy in app storage), then bootstrap from it. */
    private fun localTarball(uri: Uri) = bg {
        val size = contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getLong(0) else -1L } ?: -1L
        log("· copying picked file to ${Paths.DL_FILE} (${size / 1048576} MiB)")
        val input = contentResolver.openInputStream(uri) ?: run { log("cannot open file"); return@bg }
        val counted = Counting(input) { n ->
            setProgress(Progress("copy", if (size > 0) (n * 100 / size).toInt() else -1, "Copying ${n / 1048576} / ${size / 1048576} MiB"))
        }
        val rc = RootShell.run(Scripts.receiveFile(Paths.DL_FILE), counted, ::log)
        if (rc != 0) { log("copy failed (exit $rc). Enough space on /data?"); setProgress(null); return@bg }
        startJob(force = st.rootfs, file = Paths.DL_FILE)
    }

    private fun mitm(uri: Uri?) = bg {
        val rc = if (uri == null) {
            log("$ mitmca-add <chroot ~/.mitmproxy/mitmproxy-ca-cert.pem>")
            RootShell.run(Scripts.mitmFromChroot, onLine = ::log)
        } else {
            val tmp = "/data/local/tmp/flip4lab-ca/ca.pem"
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
            if (bytes.isEmpty() || bytes.size > 65536) { log("not a certificate file"); return@bg }
            var r = RootShell.run(Scripts.receiveFile(tmp), bytes.inputStream(), ::log)
            if (r == 0) r = RootShell.run(Scripts.mitmAdd(tmp) + "; rc=$?; rm -f ${shQuote(tmp)}; exit \$rc", onLine = ::log)
            r
        }
        log("exit $rc")
        if (rc == 0) ui.post { confirmReboot("CA added. It's injected into apps at boot: reboot now?") }
    }

    private class Counting(i: InputStream, val cb: (Long) -> Unit) : FilterInputStream(i) {
        var n = 0L; var last = 0L
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val r = super.read(b, off, len)
            if (r > 0) { n += r; if (n - last > 8 shl 20) { last = n; cb(n) } }
            return r
        }
    }

    companion object {
        const val REQ_TARBALL = 1
        const val REQ_CA = 2
        const val REQ_PERM = 3
        const val TERMUX_PERM = "com.termux.permission.RUN_COMMAND"
    }
}
