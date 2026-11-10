package io.github.legendarymsr.flip4lab

// Pure logic (no Android imports) so it can be unit-tested on the JVM:
// the shell scripts the app runs through `su`, and parsers for their output.

object Paths {
    const val KSUD = "/data/adb/ksud"
    const val MOD = "/data/adb/modules/nixchroot"
    const val MOD_UPDATE = "/data/adb/modules_update/nixchroot"
    const val MITM_MOD = "/data/adb/modules/mitm-cacert"
    const val MITM_MOD_UPDATE = "/data/adb/modules_update/mitm-cacert"
    const val CONF = "/data/adb/nixchroot/config"
    const val DL_DIR = "/data/local/tmp/nixchroot-dl"
    const val ROOTFS_NAME = "flip4-nix-rootfs-aarch64.tar.gz"
    const val DL_FILE = "$DL_DIR/$ROOTFS_NAME"
    const val JOB_LOG = "/data/local/tmp/flip4lab-job.log"
    const val JOB_PID = "/data/local/tmp/flip4lab-job.pid"
    const val TERMUX_HOME = "/data/data/com.termux/files/home"
    const val JOB_DONE = "FLIP4LAB_JOB_EXIT="
}

fun shQuote(s: String): String = "'" + s.replace("'", "'\\''") + "'"

object Scripts {
    /** Prints key=value lines; see [Status.parse]. */
    val status = """
        echo uid=$(id -u)
        [ -x ${Paths.KSUD} ] && echo ksud=1 && echo ksud_version="$(${Paths.KSUD} -V 2>/dev/null | head -n1)"
        modstate() { # dir updatedir
          if [ -d "${'$'}2" ]; then echo pending
          elif [ -d "${'$'}1" ] && [ -f "${'$'}1/remove" ]; then echo remove
          elif [ -d "${'$'}1" ] && [ -f "${'$'}1/disable" ]; then echo disabled
          elif [ -d "${'$'}1" ]; then echo installed
          else echo none; fi
        }
        echo module=$(modstate ${Paths.MOD} ${Paths.MOD_UPDATE})
        echo module_version=$(grep '^version=' ${Paths.MOD}/module.prop 2>/dev/null | cut -d= -f2)
        echo mitm=$(modstate ${Paths.MITM_MOD} ${Paths.MITM_MOD_UPDATE})
        NIXROOT=/data/local/nix
        [ -r ${Paths.CONF} ] && . ${Paths.CONF}
        echo nixroot=${'$'}NIXROOT
        if [ -d "${'$'}NIXROOT/nix/store" ] && [ -L "${'$'}NIXROOT/nix/var/nix/profiles/default" ]; then echo rootfs=1; else echo rootfs=0; fi
        echo rootfs_pin=$(. ${Paths.MOD}/rootfs.env 2>/dev/null; echo "${'$'}ROOTFS_SHA256")
        echo rootfs_pin_rev=$(. ${Paths.MOD}/rootfs.env 2>/dev/null; echo "${'$'}ROOTFS_NIXPKGS_REV")
        echo rootfs_installed=$(cat "${'$'}NIXROOT/.rootfs-sha256" 2>/dev/null)
        echo mounts=$(cut -d' ' -f5 /proc/1/mountinfo | grep -cE "^${'$'}NIXROOT(/|${'$'})")
        echo partial=$(stat -c %s ${Paths.DL_DIR}/${Paths.ROOTFS_NAME}.part 2>/dev/null || echo 0)
        p=$(cat ${Paths.JOB_PID} 2>/dev/null); [ -n "${'$'}p" ] && [ -d /proc/${'$'}p ] && echo job=1 || echo job=0
        [ -d ${Paths.TERMUX_HOME} ] && echo termux=1 || echo termux=0
        grep -qs '^ *allow-external-apps *= *true' ${Paths.TERMUX_HOME}/.termux/termux.properties && echo termux_ext=1 || echo termux_ext=0
        echo mitm_certs=$(ls /data/adb/mitmca/certs.d 2>/dev/null | grep -c '\.0${'$'}')
        echo boot_completed=$(getprop sys.boot_completed)
    """.trimIndent()

    fun installModule(zip: String) = "${Paths.KSUD} module install ${shQuote(zip)}"

    const val REBOOT = "svc power reboot || /system/bin/reboot"

    fun nixroot(vararg args: String): String =
        (listOf("sh ${Paths.MOD}/nixroot") + args.map(::shQuote)).joinToString(" ")

    fun bootstrapArgs(force: Boolean, file: String?): List<String> =
        buildList {
            add("--bootstrap")
            if (force) add("--force")
            if (file != null) { add("--file"); add(file) }
        }

    /**
     * Run [inner] detached from the app: own session, moved out of the app's
     * cgroup (so closing the app doesn't kill a 1.2 GiB download), wakelock
     * held, output to a log the UI tails. Exit code lands as the last line.
     */
    fun detached(inner: String): String {
        val body = """
            echo ${'$'}${'$'} > ${Paths.JOB_PID}
            echo ${'$'}${'$'} > /sys/fs/cgroup/cgroup.procs 2>/dev/null
            echo flip4lab > /sys/power/wake_lock 2>/dev/null
            ( $inner ); rc=${'$'}?
            echo flip4lab > /sys/power/wake_unlock 2>/dev/null
            rm -f ${Paths.JOB_PID}
            echo "${Paths.JOB_DONE}${'$'}rc"
        """.trimIndent()
        return "rm -f ${Paths.JOB_LOG}; setsid sh -c ${shQuote(body)} > ${Paths.JOB_LOG} 2>&1 < /dev/null &\necho started"
    }

    /**
     * Follow the job log from the start until the job's exit marker, then
     * exit by itself (the app can't signal a root process, so `tail -f` would
     * linger). Synthesises an exit marker if the job died without one.
     */
    val tailJob = """
        L=${Paths.JOB_LOG}; i=1; dead=0
        [ -f "${'$'}L" ] || { echo "${Paths.JOB_DONE}255"; exit 0; }
        while :; do
          n=$(wc -l < "${'$'}L")
          if [ "${'$'}n" -ge "${'$'}i" ]; then
            chunk=$(sed -n "${'$'}{i},${'$'}{n}p" "${'$'}L"); i=$((n + 1))
            printf '%s\n' "${'$'}chunk"
            case "${'$'}chunk" in *${Paths.JOB_DONE}*) exit 0 ;; esac
          fi
          p=$(cat ${Paths.JOB_PID} 2>/dev/null)
          if [ -z "${'$'}p" ] || [ ! -d "/proc/${'$'}p" ]; then
            dead=$((dead + 1))
            [ ${'$'}dead -ge 3 ] && { echo "${Paths.JOB_DONE}137"; exit 0; }
          else dead=0; fi
          sleep 1
        done
    """.trimIndent()

    /** Data for this is fed on stdin. */
    fun receiveFile(dest: String) =
        "mkdir -p ${shQuote(dest.substringBeforeLast('/'))} && chmod 700 ${shQuote(dest.substringBeforeLast('/'))} && cat > ${shQuote("$dest.copy")} && mv -f ${shQuote("$dest.copy")} ${shQuote(dest)}"

    fun mitmAdd(pem: String) = "sh ${Paths.MITM_MOD}/mitmca-add ${shQuote(pem)}"

    /** Generate the chroot's mitmproxy CA if needed and install it. */
    val mitmFromChroot = """
        NIXROOT=/data/local/nix; [ -r ${Paths.CONF} ] && . ${Paths.CONF}
        ca=${'$'}NIXROOT/root/.mitmproxy/mitmproxy-ca-cert.pem
        if [ ! -f "${'$'}ca" ]; then
          echo "generating mitmproxy CA in the chroot ..."
          ${nixroot("sh", "-c", "timeout 15 mitmdump -q --listen-port 0 >/dev/null 2>&1; true")}
        fi
        [ -f "${'$'}ca" ] || { echo "no CA at ${'$'}ca"; exit 1; }
        sh ${Paths.MITM_MOD}/mitmca-add "${'$'}ca"
    """.trimIndent()

    /**
     * Let other apps (us) start commands in Termux: allow-external-apps=true.
     * Idempotent: only writes, and only restarts Termux (so it re-reads the
     * file), when the setting actually changes. Last line: TERMUX_EXT=changed|unchanged.
     */
    val enableTermuxExternal = """
        H=${Paths.TERMUX_HOME}
        [ -d "${'$'}H" ] || { echo "Termux not installed (or never opened)"; exit 3; }
        f="${'$'}H/.termux/termux.properties"
        if grep -qs '^ *allow-external-apps *= *true *${'$'}' "${'$'}f"; then
          echo "allow-external-apps already true"; echo TERMUX_EXT=unchanged; exit 0
        fi
        own=$(stat -c %u:%g "${'$'}H")
        mkdir -p "${'$'}H/.termux"
        if grep -qs '^ *allow-external-apps *=' "${'$'}f"; then
          sed -i 's/^ *allow-external-apps *=.*/allow-external-apps = true/' "${'$'}f"
        else
          echo 'allow-external-apps = true' >> "${'$'}f"
        fi
        chown "${'$'}own" "${'$'}H/.termux" "${'$'}f"; chmod 700 "${'$'}H/.termux"; chmod 600 "${'$'}f"
        restorecon -R "${'$'}H/.termux" 2>/dev/null
        # Termux caches termux.properties; a restart makes it re-read them.
        am force-stop com.termux 2>/dev/null
        echo "allow-external-apps = true written to ${'$'}f (Termux restarted once)"
        echo TERMUX_EXT=changed
    """.trimIndent()

    /** Command Termux runs in its new foreground session. */
    val termuxShellArgs = listOf("-c", "sh ${Paths.MOD}/nixroot")

    /**
     * Fallback that sidesteps background-start limits: root's `am` starts
     * Termux's RunCommandService as a foreground service, after bringing
     * TermuxActivity to the front.
     */
    val termuxViaRoot: String = """
        am start -n com.termux/.app.TermuxActivity >/dev/null 2>&1
        sleep 1
        am start-foreground-service -n com.termux/.app.RunCommandService -a com.termux.RUN_COMMAND \
          --es com.termux.RUN_COMMAND_PATH /system/bin/su \
          --esa com.termux.RUN_COMMAND_ARGUMENTS ${shQuote(termuxShellArgs.joinToString(","))} \
          --ez com.termux.RUN_COMMAND_BACKGROUND false \
          --es com.termux.RUN_COMMAND_SESSION_ACTION 0
    """.trimIndent()

    private val interactive = setOf(
        "bash", "sh", "zsh", "fish", "ash", "python", "python3", "ipython", "node", "irb",
        "vim", "vi", "nvim", "nano", "less", "more", "top", "htop", "tmux", "screen",
        "mitmproxy", "frida", "r2", "rizin", "gdb", "nix-shell", "ssh", "sqlite3",
    )

    /**
     * Turn the "Run in chroot" text into a script, or explain why not.
     * Commands get no stdin, so bare interactive programs are refused with a
     * hint instead of exiting oddly.
     */
    fun chrootCommand(input: String): Result<String> {
        val c = input.trim()
        if (c.isEmpty()) return Result.failure(IllegalArgumentException("Type a command first, e.g. nix --version"))
        val words = c.split(Regex("\\s+"))
        val prog = words.first().substringAfterLast('/')
        val bareShell = words.size == 1 && prog in interactive
        val nixShell = prog == "nix" && words.getOrNull(1) in setOf("shell", "develop", "repl") && "-c" !in words && "--command" !in words
        if (bareShell || nixShell)
            return Result.failure(IllegalArgumentException("'$c' is interactive: use Open shell (Termux) for that. This box runs one-shot commands with no input."))
        return Result.success(nixroot("bash", "-lc", "exec </dev/null; $c"))
    }
}

data class Status(val kv: Map<String, String>) {
    val root get() = kv["uid"] == "0"
    val ksud get() = kv["ksud"] == "1"
    val module get() = kv["module"] ?: "none"
    val moduleUsable get() = module == "installed"
    val rebootPending get() = module == "pending" || mitm == "pending"
    val mitm get() = kv["mitm"] ?: "none"
    val rootfs get() = kv["rootfs"] == "1"
    /** Installed rootfs isn't the one this module pins (older installs have no marker). */
    val rootfsOutdated get() = rootfs && !kv["rootfs_pin"].isNullOrEmpty() && kv["rootfs_installed"] != kv["rootfs_pin"]
    val mounts get() = kv["mounts"]?.toIntOrNull() ?: 0
    val mounted get() = mounts > 0
    val partialBytes get() = kv["partial"]?.toLongOrNull() ?: 0L
    val jobRunning get() = kv["job"] == "1"
    val termux get() = kv["termux"] == "1"
    val termuxExternal get() = kv["termux_ext"] == "1"
    val nixroot get() = kv["nixroot"] ?: "/data/local/nix"

    /** The one thing the user should do next. */
    val next: String get() = when {
        !root -> "Grant root: KernelSU manager → Superuser → enable Flip4 Nix Lab, then Refresh."
        !ksud -> "KernelSU (ksud) not found at ${Paths.KSUD}."
        module == "none" -> "Tap Install module."
        rebootPending -> "Reboot to activate the module."
        module != "installed" -> "Module is $module in KernelSU manager; re-enable it and reboot."
        jobRunning -> "Working… (you can leave the app; it keeps going)"
        !rootfs -> if (partialBytes > 0) "Tap Set up to resume the download." else "Tap Set up (downloads ~1.2 GiB)."
        rootfsOutdated -> "Rootfs update available (toolset from nixpkgs ${kv["rootfs_pin_rev"]?.take(7) ?: "?"}): tap Reinstall."
        !mounted -> "Tap Mount (or reboot)."
        else -> "Ready. Tap Open shell."
    }

    companion object {
        fun parse(out: String): Status = Status(
            out.lineSequence().mapNotNull { l ->
                val i = l.indexOf('=')
                if (i <= 0) null else l.substring(0, i).trim() to l.substring(i + 1).trim()
            }.toMap()
        )
    }
}

data class Progress(val phase: String, val percent: Int, val text: String)

object ProgressParser {
    // bootstrap.sh: "  ... 123 / 1231 MiB (9%)" and "  extract: 40 / 522 store paths (7%)"
    private val dl = Regex("""^\s*\.\.\.\s+(\d+)\s*/\s*(\d+)\s*MiB\s*\((\d+)%\)""")
    private val ex = Regex("""^\s*extract:\s+(\d+)\s*/\s*(\d+).*\((\d+)%\)""")
    private val copy = Regex("""^copy:\s+(\d+)\s*/\s*(\d+)\s*MiB""")

    fun parse(line: String): Progress? {
        dl.find(line)?.let { m ->
            return Progress("download", m.groupValues[3].toInt().coerceIn(0, 100), "Downloading ${m.groupValues[1]} / ${m.groupValues[2]} MiB")
        }
        ex.find(line)?.let { m ->
            return Progress("extract", m.groupValues[3].toInt().coerceIn(0, 100), "Extracting ${m.groupValues[1]} / ${m.groupValues[2]} store paths")
        }
        copy.find(line)?.let { m ->
            val a = m.groupValues[1].toLong(); val b = m.groupValues[2].toLong().coerceAtLeast(1)
            return Progress("copy", (a * 100 / b).toInt().coerceIn(0, 100), "Copying $a / $b MiB")
        }
        return when {
            line.contains("verifying sha256") -> Progress("verify", -1, "Verifying sha256…")
            line.contains("extracting to") -> Progress("extract", 0, "Extracting…")
            line.contains("mounting ...") -> Progress("mount", -1, "Mounting…")
            line.startsWith("done.") -> Progress("done", 100, "Done")
            else -> null
        }
    }

    fun exitCode(line: String): Int? =
        if (line.startsWith(Paths.JOB_DONE)) line.removePrefix(Paths.JOB_DONE).trim().toIntOrNull() else null
}
