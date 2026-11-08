package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.phone.background.Reasons
import io.github.ccch1mneyyy.dsh_app.phone.skills.PhoneTaskTrace
import java.time.ZoneId
import java.util.concurrent.atomic.AtomicReference

enum class A11yState { CONNECTED, ENABLED_NOT_CONNECTED, DISABLED }

/** What the core needs from the device; [PhoneControl] on Android, a fake in the JVM tests. */
interface PhoneEnv {
    /** The master switch. */
    fun enabled(): Boolean
    fun policies(): PhonePolicies
    fun isLocked(): Boolean
    fun gate(): UserGate?
    fun driver(screen: PhoneScreen): PhoneDriver?
    fun driver(screen: PhoneScreen, owner: PhoneTasks.Owner): PhoneDriver? = driver(screen)
    fun a11yState(): A11yState
    /** Why the background display can't be used, as a sentence for the model. */
    fun backgroundUnavailable(): String
    fun system(): SystemApi
    fun uiText(): PhoneUiText = PhoneUiText.DEFAULT
    fun zone(): ZoneId
    /** Tells the person what to fix (accessibility off, …); at most once per task and kind. */
    fun notifyFix(kind: String)
    /** New native task only, under its current-owner check; no rendering or IO. */
    fun onTaskStarted(owner: PhoneTasks.Owner) {}
    /**
     * Before `handoff`, strictly release only this call's original background resource.
     * Cleanup may outlive the active Owner; it must never adopt a successor's resource.
     */
    fun beforeHandoff(screen: PhoneScreen, owner: PhoneTasks.Owner): String? = null
    fun sleep(ms: Long) = Thread.sleep(ms)
}

/**
 * Runs the fixed tool set: argument checks, screen-id routing (`s` main / `b` background,
 * never falling back across screens), the safety rules, the selected serial worker with per-call budgets,
 * the post-action screen, and the action log. [call] is what the MCP server invokes.
 */
class PhoneCore(
    private val env: PhoneEnv,
    val tasks: PhoneTasks,
    val log: ActionLog,
    val worker: SerialWorker = SerialWorker("dsh-phone"),
    val skillTrace: PhoneTaskTrace = PhoneTaskTrace(),
    private val onExecution: (PhoneTasks.Owner) -> (((() -> Unit) -> Boolean)?) = { owner ->
        { update -> tasks.runIfCurrent(owner, update) }
    },
) {
    private val ui: PhoneUiText get() = env.uiText()
    val safety = SafetyGate(env::policies, tasks, env::gate, uiText = env.uiText())

    // An abandoned body may overlap a later execution of the same Owner. Keep its display
    // serial with that body, not a mutable Core-wide field or a fresh lookup when say runs.
    private val executionStatus = ThreadLocal<((() -> Unit) -> Boolean)>()

    /** The overlay's status line; 免确认 stays visible the whole time nothing is asked. */
    private fun say(owner: PhoneTasks.Owner, text: String) {
        if (!current(owner)) return
        val guard = executionStatus.get() ?: return
        env.gate()?.status(if (safety.waived()) ui.get("phone_waived_status", "免确认 · %1\$s", text) else text, guard) // l10n:keep test default
    }

    /** The screen of the last screen-based call, for `handoff`. */
    @Volatile private var lastScreen: PhoneScreen = PhoneScreen.MAIN

    /**
     * The task's last hard refusal (密码框, 系统设置, 不碰名单), for the `handoff` that usually
     * follows it: the card says which rule it was. Cleared by a write that went through, a new
     * task, or the handoff it named.
     */
    @Volatile private var refusal: Pair<PhoneTasks.Owner, HandoffCause>? = null

    private class Out(
        val text: String,
        val error: Boolean = false,
        val screen: ScreenSnapshot? = null,
        val app: String? = null,
        val summary: String? = null,
        val decision: String? = null,
    )

    /** One invocation's native plan. Never re-resolve it after resource admission. */
    internal class PreparedCall(
        val name: String, val args: Args, val owner: PhoneTasks.Owner,
        val screens: List<PhoneScreen>, val launch: SystemLaunch? = null,
        val shareSubject: AppEntry? = null,
    ) {
        // Only Sessions reads/writes acquisition under its registry lock; never a Core-wide grant.
        internal var borrowedMainForBackgroundOpen = false
        @Volatile internal var backgroundOpenConfirmed = false
        val knownApp: PhoneAppIdentity? get() = (launch?.target as? SystemTarget.Known)?.app?.identity
        // A MAIN observation has no trustworthy window UID. BG open only queries the
        // selected package on MAIN before moving it; its actual target is checked by T1a.
        val unknownApp: Boolean get() = PhoneScreen.MAIN in screens &&
            !(name == PhoneToolCatalog.OPEN && args.bool("background") == true)
    }

    /** Production Sessions already owns begin/callStarted; PM work never takes the action worker. */
    internal fun prepareCall(name: String, args: Map<String, Any?>, owner: PhoneTasks.Owner): Either<ToolOutput, PreparedCall> {
        val result = try { prepare(name, Args(args.toMap()), owner) }
        catch (_: InterruptedException) { Thread.currentThread().interrupt(); Either.Left(stoppedOut(name)) }
        catch (e: Exception) { Either.Left(failedOut(name, e)) }
        return when (result) {
            is Either.Left -> { tasks.touch(owner); Either.Left(output(name, owner, result.value)) }
            is Either.Right -> result
        }
    }

    internal fun call(prepared: PreparedCall, executionWorker: SerialWorker): ToolOutput =
        runCall(prepared.name, prepared.args, AtomicReference<PhoneTasks.Owner?>(prepared.owner), prepared, executionWorker)

    fun call(name: String, args: Map<String, Any?>, admittedOwner: PhoneTasks.Owner? = null): ToolOutput {
        // In flight from here until the result goes back: no turn ends while a call runs (PhoneTasks.finish).
        val owner = AtomicReference(admittedOwner)
        if (admittedOwner == null) tasks.callStarted()
        try {
            return runCall(name, Args(args), owner)
        } finally {
            if (admittedOwner == null) tasks.callEnded(owner.get())
        }
    }

    /** Cheap refusals must not start a native task or acquire a screen lease. */
    internal fun rejection(name: String): ToolOutput? {
        if (name !in PhoneToolCatalog.names) {
            // l10n:keep agent tool result
            return ToolOutput("没有这个手机工具：$name。可用：${PhoneToolCatalog.names.joinToString("、")}", isError = true)
        }
        if (!env.enabled()) {
            // l10n:keep agent tool result
            return ToolOutput("手机操控已在 DSH 设置里关闭。请用户在 设置 → 手机操控 里打开后重启引擎。", isError = true)
        }
        return null
    }

    private fun runCall(name: String, args: Args, callOwner: AtomicReference<PhoneTasks.Owner?>, prepared: PreparedCall? = null,
                        executionWorker: SerialWorker = worker): ToolOutput {
        rejection(name)?.let { return it }
        val outcome = executionWorker.run(budgetMs(name), MAX_TOTAL_MS, owner = tasks) { scope -> execute(name, args, scope, callOwner, prepared) }
        val owner = callOwner.get()
        if (owner != null && name in TRACE_ACTIONS && outcome !is SerialWorker.Outcome.Done) {
            skillTrace.markIncomplete(owner, PhoneTaskTrace.Gap.UNCERTAIN_RESULT)
        }
        tasks.touch(owner)
        val out = when (outcome) {
            is SerialWorker.Outcome.Done -> outcome.value
            is SerialWorker.Outcome.TimedOut -> {
                val text = if (outcome.queued) {
                    // l10n:keep agent tool result
                    "前面的手机操作还没结束，这一步没有执行。稍后再试。"
                } else {
                    // l10n:keep agent tool result
                    "这一步超时了，可能执行了也可能没有。不要自动重试同一个动作：先用 screen 看看现在的屏幕。"
                }
                Out(text, error = true, summary = name, decision = "timeout")
            }
            SerialWorker.Outcome.Interrupted -> Out(PhoneTasks.STOPPED_MESSAGE + "。", error = true, summary = name, decision = "stopped")
            is SerialWorker.Outcome.Failed -> failedOut(name, outcome.error)
        }
        return output(name, owner, out)
    }

    private fun failedOut(name: String, error: Throwable) = Out(
        // l10n:keep agent tool result
        "手机操作出错：${error.javaClass.simpleName}${error.message?.let { "：$it" } ?: ""}",
        error = true, summary = name, decision = "error",
    )

    private fun output(name: String, owner: PhoneTasks.Owner?, out: Out): ToolOutput {
        out.summary?.let { log.add(name, out.app, it, out.decision ?: if (out.error) "error" else "ok") }
        var interjections = emptyList<String>()
        if (owner != null) tasks.runIfCurrent(owner) {
            noteRefusal(name, out.decision, owner)
            interjections = tasks.drainInterjections()
        }
        val text = buildString {
            // l10n:keep agent tool result
            for (line in interjections) append("用户插话：「").append(line).append("」\n\n")
            append(out.text)
            out.screen?.let { if (out.text.isNotEmpty()) append("\n\n"); append(it.text) }
        }
        val image = out.screen?.image
        return ToolOutput(text, out.error, image, if (image != null) out.screen.imageMime else null)
    }

    private fun noteRefusal(tool: String, decision: String?, owner: PhoneTasks.Owner) {
        val cause = HandoffCause.ofDecision(decision)
        if (cause != null) {
            refusal = owner to cause
        } else if (tool in WRITES && decision in DONE) {
            refusal = null
        }
    }

    private fun execute(name: String, a: Args, scope: SerialWorker.Scope, callOwner: AtomicReference<PhoneTasks.Owner?>, prepared: PreparedCall?): Out {
        val admitted = callOwner.get()
        val owner = admitted ?: when (val b = tasks.begin()) {
            is PhoneTasks.Begin.Refused -> return Out(b.message + "。", error = true, summary = name, decision = "stopped")
            is PhoneTasks.Begin.Go -> b.owner.also {
                callOwner.set(it)
                if (b.newTask) tasks.runIfCurrent(it) {
                    skillTrace.start(it)
                    env.onTaskStarted(it)
                }
            }
        }
        if (!current(owner)) return stoppedOut(name)
        val displayGuard = onExecution(owner) ?: return stoppedOut(name)
        executionStatus.set(displayGuard)
        try {
            if (tasks.isPaused) {
                if (admitted != null) return Out("用户已暂停本任务，没有执行。请等待用户恢复。", error = true, summary = name, decision = "paused") // l10n:keep agent pause result
                val go = scope.userWait { tasks.awaitResume(PAUSE_WAIT_MS) }
                if (!go) {
                    // Stopped, or the task ended under the wait (the engine went away): never go on.
                    return if (tasks.isStopped() || !tasks.isActive) {
                        Out(PhoneTasks.STOPPED_MESSAGE + "。", error = true, summary = name, decision = "stopped")
                    } else {
                        // l10n:keep agent tool result
                        Out("用户暂停了手机操作，超过 10 分钟没有恢复。停下来，告诉用户可以恢复后再继续。", error = true, summary = name, decision = "paused")
                    }
                }
            }
            if (!current(owner)) return stoppedOut(name)
            // Direct Core callers retain their original begin/pause timing. Both paths use
            // this one preparer; production arrives with the already-admitted native plan.
            val call = prepared ?: when (val result = prepare(name, a, owner)) {
                is Either.Left -> return result.value
                is Either.Right -> result.value
            }
            if (!current(owner)) return stoppedOut(name)
            return when (name) {
                PhoneToolCatalog.APPS -> apps(a, owner)
                PhoneToolCatalog.OPEN -> open(call, scope, owner)
                PhoneToolCatalog.INTENT -> intent(call, owner)
                PhoneToolCatalog.NOTIFY -> notify(a, owner)
                PhoneToolCatalog.CLIPBOARD -> clipboard(a, owner)
                PhoneToolCatalog.SCREEN -> screen(a, owner)
                PhoneToolCatalog.COLLECT -> collect(a, owner)
                PhoneToolCatalog.TAP, PhoneToolCatalog.TYPE, PhoneToolCatalog.SCROLL, PhoneToolCatalog.TAP_XY -> act(name, a, scope, owner)
                PhoneToolCatalog.KEY -> key(a, owner)
                PhoneToolCatalog.HANDOFF -> handoff(a, scope, owner)
                // l10n:keep agent tool result
                else -> Out("没有这个手机工具：$name", error = true)
            }
        } finally {
            executionStatus.remove()
        }
    }

    private fun current(owner: PhoneTasks.Owner): Boolean =
        tasks.isCurrent(owner) && !Thread.currentThread().isInterrupted

    // ── System actions ──────────────────────────────────────────────────────────────

    private fun apps(a: Args, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("apps")
        val q = a.str("query")
        val listed = env.system().apps()
        if (!current(owner)) return stoppedOut("apps")
        val all = listed.filter { it.packageName != SafetyRules.OWN_PACKAGE }.sortedBy { it.label }
        val hits = AppMatch.filter(all, q)
        if (hits.isEmpty()) return Out(if (q == null) "没读到应用列表。" else "没有找到名称或包名含「$q」的应用。", summary = ui.get("phone_log_apps", "列出应用")) // l10n:keep test default
        val shown = hits.take(MAX_APPS)
        val text = buildString {
            // l10n:keep agent tool result
            append(if (q == null) "共 ${hits.size} 个应用" else "匹配「$q」的应用 ${hits.size} 个").append("（名称 · 包名）：\n")
            shown.forEach { append(it.label).append(" · ").append(it.packageName).append('\n') }
            // l10n:keep agent tool result
            if (hits.size > shown.size) append("…另有 ${hits.size - shown.size} 个，用 query 缩小范围\n")
        }.trimEnd()
        return Out(text, summary = if (q == null) ui.get("phone_log_apps", "列出应用") else ui.get("phone_log_apps_filtered", "列出应用（筛选）")) // l10n:keep test default
    }

    private fun resolveApp(query: String): Either<String, AppEntry> =
        when (val r = AppMatch.resolve(env.system().apps(), query)) {
            is AppMatch.Result.Found -> Either.Right(r.app)
            is AppMatch.Result.Ambiguous -> Either.Left(
                // l10n:keep agent tool result
                "「$query」对应多个应用，请用包名指定：" + r.candidates.joinToString("；") { "${it.label} · ${it.packageName}" },
            )
            // l10n:keep agent tool result
            AppMatch.Result.NotFound -> Either.Left("没找到应用「$query」。用 apps 查一下名称或包名。")
        }

    private fun prepare(name: String, a: Args, owner: PhoneTasks.Owner): Either<Out, PreparedCall> {
        if (!current(owner)) return Either.Left(stoppedOut(name))
        val screens = when (val route = requiredScreens(name, a)) {
            is Either.Left -> return Either.Left(Out(route.value, error = true))
            is Either.Right -> route.value
        }
        var launch: SystemLaunch? = null
        var shareSubject: AppEntry? = null
        when (name) {
            PhoneToolCatalog.OPEN -> {
                val appQ = a.str("app")
                val url = a.str("url")
                // l10n:keep agent tool result
                if ((appQ == null) == (url == null)) return Either.Left(Out("open 需要 app 或 url，二选一。", error = true))
                if (env.isLocked()) return Either.Left(locked("open"))
                if (url != null) {
                    // l10n:keep agent tool result
                    if (a.bool("background") == true) return Either.Left(Out("后台屏只能用 app 打开应用，不支持链接。", error = true))
                    UrlPolicy.check(url)?.let {
                        return Either.Left(Out(it, error = true, summary = ui.get("phone_log_open_url", "打开链接"), decision = "refused:url")) // l10n:keep test default
                    }
                    launch = when (val result = env.system().prepareUrl(url)) {
                        is Either.Left -> return Either.Left(Out(result.value, error = true, decision = "refused:url"))
                        is Either.Right -> result.value
                    }
                } else {
                    val selected = when (val result = resolveApp(checkNotNull(appQ))) {
                        is Either.Left -> return Either.Left(Out(result.value, error = true))
                        is Either.Right -> result.value
                    }
                    launch = when (val result = env.system().prepareLaunch(selected)) {
                        is Either.Left -> return Either.Left(Out(result.value, error = true))
                        is Either.Right -> result.value
                    }
                    if (launch.target !is SystemTarget.Known)
                        return Either.Left(Out(Reasons.of("targetIdentityUnavailable"), error = true))
                }
            }
            PhoneToolCatalog.INTENT -> {
                val spec = when (val parsed = IntentSpec.parse(a, env.zone())) {
                    is Either.Left -> return Either.Left(Out(parsed.value, error = true))
                    is Either.Right -> parsed.value
                }
                val kind = a.str("kind") ?: ""
                if (env.isLocked()) return Either.Left(locked("intent $kind"))
                val appQuery = when (spec) {
                    is IntentSpec.Share -> spec.app
                    is IntentSpec.Settings -> spec.app
                    else -> null
                }
                val selected = appQuery?.let { query ->
                    when (val result = resolveApp(query)) {
                        is Either.Left -> return Either.Left(Out(result.value, error = true))
                        is Either.Right -> result.value
                    }
                }
                if (spec is IntentSpec.Share) shareSubject = selected
                launch = when (val result = env.system().prepareIntent(spec, selected)) {
                    is Either.Left -> return Either.Left(Out(result.value, error = true, summary = "intent $kind", decision = "refused:identity"))
                    is Either.Right -> result.value
                }
            }
        }
        if (!current(owner)) return Either.Left(stoppedOut(name))
        return Either.Right(PreparedCall(name, a, owner, screens, launch, shareSubject))
    }

    private fun open(call: PreparedCall, scope: SerialWorker.Scope, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("open")
        val a = call.args
        val url = a.str("url")
        val background = a.bool("background") == true
        if (env.isLocked()) return locked("open")
        val plan = checkNotNull(call.launch)
        if (url != null) {
            val target = (plan.target as? SystemTarget.Known)?.app
            target?.let { handler ->
                safety.checkOpen(handler.packageName, handler.label)?.let { refusal ->
                    return Out(refusal.message, error = true, app = handler.label, decision = "refused:${refusal.rule}")
                }
            }
            if (!current(owner)) return stoppedOut("open")
            skillTrace.markIncomplete(owner)
            val r = env.system().launch(plan, tasks.systemDispatch(owner))
            return afterSystem(owner, r, ui.get("phone_log_open_url_scheme", "打开链接 %1\$s:", url.substringBefore(':'))) // l10n:keep test default
        }
        val app = (plan.target as? SystemTarget.Known)?.app
            ?: return Out(Reasons.of("targetIdentityUnavailable"), error = true)
        safety.checkOpen(app.packageName, app.label)?.let {
            return Out(it.message, error = true, app = app.label, summary = ui.get("phone_log_open_app", "打开 %1\$s", app.packageName), decision = "refused:${it.rule}") // l10n:keep test default
        }
        if (!background) {
            if (!tasks.isCurrent(owner) || Thread.currentThread().isInterrupted) return stoppedOut("open")
            val ticket = skillTrace.beginOpen(owner, PhoneScreen.MAIN)
            val result = try {
                env.system().launch(plan, tasks.systemDispatch(owner)).also {
                    skillTrace.finish(ticket, it.ok, false, false)
                }
            } catch (e: Throwable) { skillTrace.fail(ticket); throw e }
            return afterSystem(owner, result, ui.get("phone_log_open_app", "打开 %1\$s", app.packageName)) // l10n:keep test default
        }
        val driver = env.driver(PhoneScreen.BACKGROUND, owner)
            ?: return Out(env.backgroundUnavailable(), error = true, app = app.label, summary = ui.get("phone_log_open_background", "后台屏打开 %1\$s", app.packageName), decision = "unavailable") // l10n:keep test default
        driver.availability().let { if (!it.ok) return Out(it.reason ?: "后台屏现在不可用。", error = true, summary = ui.get("phone_log_open_background", "后台屏打开 %1\$s", app.packageName), decision = "unavailable") } // l10n:keep test default
        val mainFront = runCatching { env.driver(PhoneScreen.MAIN, owner)?.foregroundPackage() }.getOrNull()
        var decision = "allowed"
        if (mainFront == app.packageName) {
            val v = safety.confirmation(ui.get("phone_move_background", "这会把「%1\$s」从你的屏幕挪到后台屏，让 DSH 在那里操作。", app.label), app.packageName, app.label, "move-to-background") // l10n:keep test default
            when (val r = safety.resolve(v, scope, owner)) {
                is SafetyGate.Result.No -> return Out(r.message, error = true, app = app.label, summary = ui.get("phone_log_open_background", "后台屏打开 %1\$s", app.packageName), decision = r.decision) // l10n:keep test default
                is SafetyGate.Result.Go -> decision = r.decision
            }
        }
        if (!tasks.isCurrent(owner) || Thread.currentThread().isInterrupted) return stoppedOut("open")
        lastScreen = PhoneScreen.BACKGROUND
        say(owner, ui.get("phone_opening_background", "DSH 正在后台屏打开「%1\$s」", app.label)) // l10n:keep test default
        if (!current(owner)) return stoppedOut("open")
        val ticket = skillTrace.beginOpen(owner, PhoneScreen.BACKGROUND)
        val res = traceResult(ticket) { driver.open(app.identity) }
        call.backgroundOpenConfirmed = res.backgroundOpenConfirmed
        if (!current(owner) || !tasks.setAppIfCurrent(owner, app.label)) return stoppedOut("open")
        if (!current(owner)) return stoppedOut("open")
        return Out(res.message, error = !res.ok, screen = res.screen?.let { safety.filterScreen(it) }, app = app.label,
            summary = ui.get("phone_log_open_background", "后台屏打开 %1\$s", app.packageName), decision = if (res.ok) decision else "failed") // l10n:keep test default
    }

    /** The handler is a dispatch fact. Only the following read describes the actual foreground UI. */
    private fun afterSystem(owner: PhoneTasks.Owner, r: SysResult, summary: String): Out {
        if (!current(owner)) return stoppedAfterSystem(r, summary)
        if (r.ok && !tasks.setAppIfCurrent(owner, r.appLabel)) return stoppedAfterSystem(r, summary)
        val screen = try {
            if (r.ok) {
                if (!current(owner)) return stoppedAfterSystem(r, summary)
                say(owner, ui.get("phone_reading_screen", "DSH 正在看屏幕")) // l10n:keep test default
                mainScreenAfter(owner, SETTLE_AFTER_LAUNCH_MS)
            } else null
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return stoppedAfterSystem(r, summary)
        }
        if (!current(owner)) return stoppedAfterSystem(r, summary)
        val expected = (r.target as? SystemTarget.Known)?.app
        val observation = if (r.ok && expected != null && screen?.packageName != expected.packageName)
            ui.get("phone_system_handler_unconfirmed", "后续读屏未确认原处理应用位于前台；不会重复启动。") // l10n:keep test default
        else ""
        return Out(r.message + if (observation.isEmpty()) "" else "\n$observation", error = !r.ok,
            screen = screen, app = screen?.appLabel ?: r.appLabel, summary = summary, decision = if (r.ok) "ok" else "failed")
    }

    /** A later stop does not retract the platform call or replace its attempted target. */
    private fun stoppedAfterSystem(r: SysResult, summary: String): Out = Out(
        PhoneTasks.STOPPED_MESSAGE + "。\n" + r.message, // l10n:keep agent tool result
        error = true, app = r.appLabel,
        summary = if (r.target != null) ui.get("phone_system_attempt_stopped", "%1\$s（已尝试；后续停止）", summary) // l10n:keep test default
            else summary,
        decision = "stopped",
    )

    private fun mainScreenAfter(owner: PhoneTasks.Owner, settleMs: Long): ScreenSnapshot? {
        if (!current(owner)) return null
        val d = env.driver(PhoneScreen.MAIN, owner) ?: return null
        if (!d.availability().ok) return null
        return try {
            if (!current(owner)) return null
            env.sleep(settleMs)
            if (!current(owner)) return null
            val snap = d.observe(detail = false, image = false)
            if (!current(owner)) return null
            safety.filterScreen(snap)
        } catch (e: InterruptedException) {
            throw e
        } catch (_: Exception) {
            null
        }
    }

    private fun intent(call: PreparedCall, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("intent")
        val kind = call.args.str("kind") ?: ""
        if (env.isLocked()) return locked("intent $kind")
        call.shareSubject?.let { subject ->
            safety.checkOpen(subject.packageName, subject.label)?.let {
                return Out(it.message, error = true, app = subject.label, summary = "intent $kind", decision = "refused:${it.rule}")
            }
        }
        val plan = checkNotNull(call.launch)
        (plan.target as? SystemTarget.Known)?.app?.let { handler ->
            safety.checkOpen(handler.packageName, handler.label)?.let {
                return Out(it.message, error = true, app = handler.label, summary = "intent $kind", decision = "refused:${it.rule}")
            }
        }
        if (!current(owner)) return stoppedOut("intent $kind")
        skillTrace.markIncomplete(owner)
        val r = env.system().launch(plan, tasks.systemDispatch(owner))
        return afterSystem(owner, r, "intent $kind")
    }

    private fun notify(a: Args, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("notify")
        // l10n:keep agent tool result
        val title = a.str("title") ?: return Out("notify 需要 title 和 text。", error = true)
        // l10n:keep agent tool result
        val text = a.str("text") ?: return Out("notify 需要 title 和 text。", error = true)
        skillTrace.markIncomplete(owner)
        val r = env.system().notify(title, text)
        return Out(r.message, error = !r.ok, summary = ui.get("phone_log_notify", "通知"), decision = if (r.ok) "ok" else "failed") // l10n:keep test default
    }

    private fun clipboard(a: Args, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("clipboard")
        val set = a.text("set")
        val get = a.bool("get") == true
        // l10n:keep agent tool result
        if (set != null && get) return Out("clipboard 的 set 和 get 一次只能用一个。", error = true)
        if (set != null) {
            skillTrace.markIncomplete(owner)
            val r = env.system().clipboardSet(set)
            return Out(r.message, error = !r.ok, summary = ui.get("phone_log_clipboard_write", "写剪贴板（%1\$d 字）", set.length), decision = if (r.ok) "ok" else "failed") // l10n:keep test default
        }
        // l10n:keep agent tool result
        if (!get) return Out("clipboard 需要 set（写入文字）或 get:true（读取）。", error = true)
        val r = env.system().clipboardGet()
        return Out(r.message, error = !r.ok, summary = ui.get("phone_log_clipboard_read", "读剪贴板"), decision = if (r.ok) "ok" else "failed") // l10n:keep test default
    }

    // ── Screens ─────────────────────────────────────────────────────────────────────

    private fun unavailable(screen: PhoneScreen): String = when (screen) {
        PhoneScreen.BACKGROUND -> env.backgroundUnavailable()
        PhoneScreen.MAIN -> when (env.a11yState()) {
            A11yState.ENABLED_NOT_CONNECTED -> {
                env.notifyFix("a11y")
                // l10n:keep agent tool result
                "无障碍服务没连上（被系统关了或还在启动）：已通知用户到系统设置重新打开。现在只能用 apps / open / intent / notify / clipboard。"
            }
            else -> {
                env.notifyFix("a11y")
                // l10n:keep agent tool result
                "无障碍没开，看不了屏幕：已通知用户到 DSH 设置 → 手机操控 开启。现在只能用 apps / open / intent / notify / clipboard。"
            }
        }
    }

    /** The driver for [screen], or the sentence explaining why there is none. */
    private fun driverFor(screen: PhoneScreen, owner: PhoneTasks.Owner): Either<String, PhoneDriver> {
        val d = env.driver(screen, owner) ?: return Either.Left(unavailable(screen))
        val av = try {
            d.availability()
        } catch (e: Exception) {
            Availability(false, null)
        }
        if (!av.ok) {
            if (screen == PhoneScreen.MAIN) env.notifyFix("a11y")
            return Either.Left(av.reason ?: unavailable(screen))
        }
        return Either.Right(d)
    }

    private fun actionScreenParameter(name: String) = if (name == PhoneToolCatalog.TAP_XY) "observation" else "screen"

    /** Admission uses the same argument coercion and routing as the actual tool body. */
    fun requiredScreens(name: String, args: Map<String, Any?>): Either<String, List<PhoneScreen>> {
        return requiredScreens(name, Args(args))
    }

    private fun requiredScreens(name: String, a: Args): Either<String, List<PhoneScreen>> {
        return when (name) {
            PhoneToolCatalog.APPS, PhoneToolCatalog.NOTIFY, PhoneToolCatalog.CLIPBOARD -> Either.Right(emptyList())
            PhoneToolCatalog.OPEN -> Either.Right(if (a.bool("background") == true)
                listOf(PhoneScreen.MAIN, PhoneScreen.BACKGROUND) else listOf(PhoneScreen.MAIN))
            PhoneToolCatalog.SCREEN -> Either.Right(listOf(if (a.bool("background") == true) PhoneScreen.BACKGROUND else PhoneScreen.MAIN))
            PhoneToolCatalog.INTENT -> Either.Right(listOf(PhoneScreen.MAIN))
            PhoneToolCatalog.HANDOFF -> Either.Right(if (lastScreen == PhoneScreen.BACKGROUND)
                listOf(PhoneScreen.MAIN, PhoneScreen.BACKGROUND) else listOf(PhoneScreen.MAIN))
            PhoneToolCatalog.TAP, PhoneToolCatalog.TYPE, PhoneToolCatalog.SCROLL, PhoneToolCatalog.TAP_XY,
            PhoneToolCatalog.COLLECT, PhoneToolCatalog.KEY -> {
                val parameter = actionScreenParameter(name)
                val id = a.str(parameter)
                if (name == PhoneToolCatalog.KEY && id == null) Either.Right(listOf(PhoneScreen.MAIN))
                else when (val route = routeScreenId(id, parameter)) {
                    is Either.Left -> route
                    is Either.Right -> Either.Right(listOf(route.value))
                }
            }
            else -> Either.Right(emptyList()) // Core reports unknown tools without touching a screen.
        }
    }

    private fun routeScreenId(id: String?, parameterName: String = "screen"): Either<String, PhoneScreen> {
        // l10n:keep agent tool result
        if (id == null) return Either.Left("缺少 $parameterName（屏幕号，如 s7）。先调用 screen 拿到屏幕号。")
        return PhoneScreen.ofScreenId(id)?.let { Either.Right(it) }
            // l10n:keep agent tool result
            ?: Either.Left("屏幕号「$id」不对：主屏以 s 开头（如 s7），后台屏以 b 开头（如 b3）。先调用 screen 拿到屏幕号。")
    }

    private fun locked(summary: String) =
        // l10n:keep agent tool result
        Out("手机锁着屏，DSH 不在锁屏状态下操作。请用户解锁后再说一声。", error = true, summary = summary, decision = "refused:locked")

    private fun screen(a: Args, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("screen")
        val which = if (a.bool("background") == true) PhoneScreen.BACKGROUND else PhoneScreen.MAIN
        val summary = if (which == PhoneScreen.BACKGROUND) ui.get("phone_log_background_read", "读后台屏") else ui.get("phone_log_screen_read", "读屏") // l10n:keep test default
        val driver = when (val d = driverFor(which, owner)) {
            is Either.Left -> return Out(d.value, error = true, summary = summary, decision = "unavailable")
            is Either.Right -> d.value
        }
        if (env.isLocked()) return locked(summary)
        lastScreen = which
        say(owner, if (which == PhoneScreen.BACKGROUND) ui.get("phone_reading_background", "DSH 正在看后台屏") else ui.get("phone_reading_screen", "DSH 正在看屏幕")) // l10n:keep test default
        if (!current(owner)) return stoppedOut(summary)
        val snap = driver.observe(detail = a.bool("detail") == true, image = a.bool("image") == true)
        if (!current(owner) || !tasks.setAppIfCurrent(owner, snap.appLabel)) return stoppedOut(summary)
        val shown = safety.filterScreen(snap)
        if (!current(owner)) return stoppedOut(summary)
        val refused = shown !== snap
        if (!refused && shown.image != null) driver.acceptVisualObservation(shown.id)
        return Out(
            // l10n:keep agent tool result
            if (refused) "没有读取这个屏幕的内容。" else "",
            error = refused,
            screen = shown,
            app = snap.appLabel ?: snap.packageName,
            summary = "$summary ${snap.id}",
            decision = if (refused) "refused:read" else "ok",
        )
    }

    private fun collect(a: Args, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("collect")
        val sid = a.str("screen")
        val which = when (val r = routeScreenId(sid)) {
            is Either.Left -> return Out(r.value, error = true)
            is Either.Right -> r.value
        }
        // l10n:keep agent tool result
        val list = a.int("list") ?: return Out("collect 需要 list（列表编号）。", error = true)
        val pages = (a.int("max_pages") ?: 10).coerceIn(1, 30)
        val summary = ui.get("phone_log_collect", "收集 %1\$s#%2\$d", sid.toString(), list) // l10n:keep test default
        val driver = when (val d = driverFor(which, owner)) {
            is Either.Left -> return Out(d.value, error = true, summary = summary, decision = "unavailable")
            is Either.Right -> d.value
        }
        if (env.isLocked()) return locked(summary)
        lastScreen = which
        val pkg = driver.foregroundPackage()
        safety.checkRead(pkg, null)?.let { return Out(it.message, error = true, app = pkg, summary = summary, decision = "refused:${it.rule}") }
        say(owner, ui.get("phone_reading_list", "DSH 正在滚动读取列表")) // l10n:keep test default
        if (!current(owner)) return stoppedOut(summary)
        skillTrace.markIncomplete(owner)
        val r = driver.collect(sid!!, list, pages, a.str("until"))
        if (!current(owner)) return stoppedOut(summary)
        val screen = r.screen?.let { safety.filterScreen(it) }
        val text = buildString {
            // l10n:keep agent tool result
            append("收集到 ${r.items.size} 条（翻了 ${r.pages} 页，停下原因：${r.stopReason}）：\n")
            var size = 0
            for ((i, item) in r.items.withIndex()) {
                val line = "${i + 1}. $item\n"
                size += line.length
                if (size > MAX_COLLECT_CHARS) {
                    // l10n:keep agent tool result
                    append("…其余 ${r.items.size - i} 条超出长度上限，没有列出\n")
                    break
                }
                append(line)
            }
        }.trimEnd()
        return Out(text, screen = screen, app = screen?.appLabel ?: pkg, summary = summary, decision = "ok")
    }

    /** tap / type / scroll / tap_xy: route, resolve, gate, perform. */
    private fun act(name: String, a: Args, scope: SerialWorker.Scope, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut(name)
        val screenParameter = actionScreenParameter(name)
        val sid = a.str(screenParameter)
        val which = when (val r = routeScreenId(sid, screenParameter)) {
            is Either.Left -> return Out(r.value, error = true)
            is Either.Right -> r.value
        }
        sid!!
        val id = a.int("id")
        val action: PhoneAction
        val kind: WriteKind
        var typed: String? = null
        var submit = false
        var point: Pair<Int, Int>? = null
        var summary: String
        when (name) {
            PhoneToolCatalog.TAP -> {
                // l10n:keep agent tool result
                id ?: return Out("tap 需要 id（元素编号）。", error = true)
                val long = a.bool("long") == true
                action = PhoneAction.Tap(sid, id, long)
                kind = if (long) WriteKind.LONG_TAP else WriteKind.TAP
                summary = if (long) ui.get("phone_log_long_tap", "长按 %1\$s#%2\$d", sid.toString(), id) else ui.get("phone_log_tap", "点 %1\$s#%2\$d", sid.toString(), id) // l10n:keep test default
            }
            PhoneToolCatalog.TYPE -> {
                // l10n:keep agent tool result
                id ?: return Out("type 需要 id（输入框编号）。", error = true)
                // l10n:keep agent tool result
                typed = a.text("text") ?: return Out("type 需要 text。", error = true)
                submit = a.bool("submit") == true
                action = PhoneAction.Type(sid, id, typed, submit)
                kind = WriteKind.TYPE
                // Masked until the input is known not to be a password or code field.
                summary = secretSummary(sid, id, submit)
            }
            PhoneToolCatalog.SCROLL -> {
                val dir = when (a.str("direction")?.lowercase()) {
                    "up" -> PhoneAction.Direction.UP
                    "down" -> PhoneAction.Direction.DOWN
                    "left" -> PhoneAction.Direction.LEFT
                    "right" -> PhoneAction.Direction.RIGHT
                    // l10n:keep agent tool result
                    else -> return Out("scroll 需要 direction：up / down / left / right。", error = true)
                }
                action = PhoneAction.Scroll(sid, id, dir)
                kind = WriteKind.SCROLL
                summary = ui.get("phone_log_scroll", "滚动 %1\$s %2\$s", sid.toString(), dir.name.lowercase()) // l10n:keep test default
            }
            else -> {
                val x = a.int("x")
                val y = a.int("y")
                // l10n:keep agent tool result
                if (x == null || y == null || x < 0 || y < 0) return Out("tap_xy 需要非负整数 x 和 y。", error = true)
                point = x to y
                val gesture = when (a.str("action") ?: if (a.has("action")) "" else "tap") {
                    "tap" -> PhoneAction.CoordinateGesture.TAP
                    "long" -> PhoneAction.CoordinateGesture.LONG
                    "swipe" -> PhoneAction.CoordinateGesture.SWIPE
                    else -> return Out("tap_xy 的 action 需要 tap / long / swipe。", error = true) // l10n:keep
                }
                val duration = if (a.has("duration_ms")) a.int("duration_ms") else 400
                val x2 = a.int("x2"); val y2 = a.int("y2")
                if (gesture == PhoneAction.CoordinateGesture.SWIPE &&
                    (x2 == null || y2 == null || x2 < 0 || y2 < 0 || duration == null || duration !in 100..2000))
                    return Out("swipe 需要非负终点 x2/y2，duration_ms 为 100–2000。", error = true) // l10n:keep
                if (gesture != PhoneAction.CoordinateGesture.SWIPE && (a.has("x2") || a.has("y2") || a.has("duration_ms")))
                    return Out("终点与 duration_ms 只用于 swipe。", error = true) // l10n:keep
                action = PhoneAction.TapXY(sid, x, y, gesture, x2, y2, (duration ?: 400).toLong())
                kind = WriteKind.TAP_XY
                summary = ui.get("phone_log_coordinate", "坐标手势 %1\$s · %2\$s", gesture.name.lowercase(), sid) // l10n:keep test default
            }
        }
        val driver = when (val d = driverFor(which, owner)) {
            is Either.Left -> return Out(d.value, error = true, summary = summary, decision = "unavailable")
            is Either.Right -> d.value
        }
        if (env.isLocked()) return locked(summary)
        lastScreen = which
        val visual = (action as? PhoneAction.TapXY)?.let { driver.coordinateTarget(it) }
        val target: TargetInfo? = if (id != null && kind != WriteKind.TAP_XY) {
            driver.target(sid, id) ?: return stale(driver, sid, summary, owner)
        } else {
            visual?.target
        }
        val secret = kind == WriteKind.TYPE && SafetyRules.isSecretTarget(target)
        if (kind == WriteKind.TYPE && !secret) {
            summary = ui.get("phone_log_type", "输入 %1\$s#%2\$d（%3\$d 字%4\$s）", sid, id!!, typed!!.length, if (submit) ui.get("phone_log_submit", "，提交") else "") // l10n:keep test default
        }
        val pkg = target?.packageName ?: driver.foregroundPackage()
        val appLabel = target?.appLabel
        val app = appLabel ?: pkg
        val verdict = safety.checkWrite(kind, target, pkg, appLabel, typed, submit, point, action as? PhoneAction.TapXY, which, visual)
        var decision = when (val r = safety.resolve(verdict, scope, owner)) {
            is SafetyGate.Result.No -> return Out(r.message, error = true, app = app, summary = summary, decision = r.decision)
            is SafetyGate.Result.Go -> r.decision
        }
        if (action is PhoneAction.TapXY && visual != null &&
            !(verdict is SafetyGate.Verdict.Confirm && verdict.reason == "tap_xy")) {
            when (val r = safety.resolve(safety.checkVisual(action, visual, owner), scope, owner)) {
                is SafetyGate.Result.No -> return Out(r.message, error = true, app = app, summary = summary, decision = r.decision)
                is SafetyGate.Result.Go -> if (r.decision != "allowed") decision = r.decision
            }
        }
        if (!tasks.isCurrent(owner) || Thread.currentThread().isInterrupted) return stoppedOut(summary)
        if (!tasks.setAppIfCurrent(owner, appLabel ?: pkg)) return stoppedOut(summary)
        say(owner, ui.get("phone_acting", "DSH 正在操作 · %1\$s", statusLine(kind, target, if (secret) SafetyRules.MASK else typed))) // l10n:keep test default
        if (!current(owner)) return stoppedOut(summary)
        val ticket = skillTrace.beginAction(owner, action, target)
        val res = traceResult(ticket) { driver.perform(action) }
        if (!res.ok && res.staleSnapshot) return stale(driver, sid, summary, owner, res.message)
        return Out(
            res.message,
            error = !res.ok,
            screen = res.screen?.let { safety.filterScreen(it) },
            app = app,
            summary = summary,
            decision = if (res.ok) decision else "failed",
        )
    }

    /** A `type` in the log without its length or text: 「输入 s3#5（••••）」. */
    private fun secretSummary(sid: String, id: Int, submit: Boolean): String =
        ui.get("phone_log_type_secret", "输入 %1\$s#%2\$d（%3\$s%4\$s）", sid, id, SafetyRules.MASK, if (submit) ui.get("phone_log_submit", "，提交") else "") // l10n:keep test default

    private fun statusLine(kind: WriteKind, t: TargetInfo?, typed: String?): String {
        val label = t?.label?.takeIf { it.isNotBlank() }?.let { SafetyRules.quoteText(it, 16) } ?: t?.role?.let(ui::role) ?: ""
        return when (kind) {
            WriteKind.TAP -> ui.get("phone_status_tap", "点「%1\$s」", label) // l10n:keep test default
            WriteKind.LONG_TAP -> ui.get("phone_status_long_tap", "长按「%1\$s」", label) // l10n:keep test default
            WriteKind.TYPE -> ui.get("phone_status_type", "输入「%1\$s」", if (typed == SafetyRules.MASK) typed else SafetyRules.quoteText(typed ?: "", 16)) // l10n:keep test default
            WriteKind.SCROLL -> ui.get("phone_status_scroll", "滚动") // l10n:keep test default
            WriteKind.TAP_XY -> ui.get("phone_status_coordinate", "执行截图坐标手势") // l10n:keep test default
            WriteKind.KEY -> ui.get("phone_status_key", "按键") // l10n:keep test default
        }
    }

    /** The element no longer matches its snapshot: refuse and show the screen as it is now. */
    private fun stale(driver: PhoneDriver, sid: String, summary: String, owner: PhoneTasks.Owner, refusal: String? = null): Out {
        val now = try {
            if (!tasks.isCurrent(owner) || Thread.currentThread().isInterrupted || env.isLocked()) null
            else {
                val pkg = driver.foregroundPackage()
                if (safety.checkRead(pkg, null) != null || !tasks.isCurrent(owner) ||
                    Thread.currentThread().isInterrupted || env.isLocked()) null
                else {
                    val observed = driver.observe(detail = false, image = false)
                    if (!tasks.isCurrent(owner) || Thread.currentThread().isInterrupted || env.isLocked()) null
                    else safety.filterScreen(observed)
                }
            }
        } catch (e: InterruptedException) {
            throw e
        } catch (_: Exception) {
            null
        }
        return Out(
            // l10n:keep agent tool result
            refusal ?: if (now != null) "屏幕 $sid 已经过期，或者这个元素变了，没有执行。按下面的新屏幕重新选。"
            // l10n:keep agent tool result
            else "屏幕 $sid 已经过期，或者这个元素变了，没有执行。请重新观察后再操作。",
            error = true,
            screen = now,
            summary = summary,
            decision = "stale",
        )
    }

    private fun key(a: Args, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("key")
        val key = when (a.str("key")?.lowercase()) {
            "back" -> PhoneAction.GlobalKey.BACK
            "home" -> PhoneAction.GlobalKey.HOME
            "recents" -> PhoneAction.GlobalKey.RECENTS
            "notifications" -> PhoneAction.GlobalKey.NOTIFICATIONS
            // l10n:keep agent tool result
            else -> return Out("key 只能是 back / home / recents / notifications。", error = true)
        }
        val sid = a.str("screen")
        val which = if (sid == null) {
            PhoneScreen.MAIN
        } else {
            when (val r = routeScreenId(sid)) {
                is Either.Left -> return Out(r.value, error = true)
                is Either.Right -> r.value
            }
        }
        val summary = ui.get("phone_log_key", "按键 %1\$s", key.name.lowercase()) // l10n:keep test default
        val driver = when (val d = driverFor(which, owner)) {
            is Either.Left -> return Out(d.value, error = true, summary = summary, decision = "unavailable")
            is Either.Right -> d.value
        }
        if (env.isLocked()) return locked(summary)
        lastScreen = which
        say(owner, ui.get("phone_status_press", "DSH 正在操作 · 按%1\$s", when (key) { // l10n:keep test default
            PhoneAction.GlobalKey.BACK -> ui.get("phone_key_back", "返回") // l10n:keep test default
            PhoneAction.GlobalKey.HOME -> ui.get("phone_key_home", "桌面") // l10n:keep test default
            PhoneAction.GlobalKey.RECENTS -> ui.get("phone_key_recents", "最近任务") // l10n:keep test default
            PhoneAction.GlobalKey.NOTIFICATIONS -> ui.get("phone_key_notifications", "通知栏") // l10n:keep test default
        }))
        if (!current(owner)) return stoppedOut(summary)
        val action = PhoneAction.Key(sid ?: "${which.prefix}0", key)
        val ticket = skillTrace.beginAction(owner, action, null)
        val res = traceResult(ticket) { driver.perform(action) }
        return Out(res.message, error = !res.ok, screen = res.screen?.let { safety.filterScreen(it) }, summary = summary,
            decision = if (res.ok) "ok" else "failed")
    }

    private inline fun traceResult(ticket: PhoneTaskTrace.Ticket?, action: () -> ActionResult): ActionResult {
        if (ticket == null) return action()
        try {
            return action().also { result ->
                val post = result.screen
                val readable = post != null && !post.secure && safety.checkRead(post.packageName, post.appLabel) == null
                skillTrace.finish(ticket, result.ok, result.staleSnapshot, readable)
            }
        } catch (e: Throwable) { skillTrace.fail(ticket); throw e }
    }

    private fun handoff(a: Args, scope: SerialWorker.Scope, owner: PhoneTasks.Owner): Out {
        if (!current(owner)) return stoppedOut("handoff")
        // l10n:keep agent tool result
        val reason = a.str("reason") ?: return Out("handoff 需要 reason：一句话告诉用户要做什么。", error = true)
        val gate = env.gate() ?: return Out(
            // l10n:keep agent tool result
            "现在没办法把手机交给用户（DSH 不能发通知，悬浮条也没开）。直接在回复里告诉用户要做什么。",
            error = true,
            summary = ui.get("phone_log_handoff", "交还用户"), // l10n:keep test default
            decision = "refused:no-gate",
        )
        var cause: HandoffCause? = null
        if (!tasks.runIfCurrent(owner) {
            cause = refusal?.takeIf { (who, _) -> tasks.isCurrent(who) && who.taskId == owner.taskId }?.second
            refusal = null
        }) return stoppedOut("handoff")
        skillTrace.markIncomplete(owner)
        val note = env.beforeHandoff(lastScreen, owner)
        if (!tasks.isCurrent(owner)) return stoppedOut("handoff")
        val result = scope.userWait { gate.handoff(reason, HANDOFF_MS, cause, owner) }
        if (!tasks.isCurrent(owner) || Thread.currentThread().isInterrupted) return stoppedOut("handoff")
        val prefix = note?.let { "$it\n" } ?: ""
        return when (result) {
            HandoffResult.CONTINUE -> {
                lastScreen = PhoneScreen.MAIN
                val screen = mainScreenAfter(owner, 0)
                if (!current(owner)) return stoppedOut("handoff")
                Out(prefix + "用户点了「继续」。下面是现在的屏幕；接着做之前先确认状态。", screen = screen, summary = ui.get("phone_log_handoff", "交还用户"), decision = "continue") // l10n:keep test default
            }
            HandoffResult.STOP -> {
                // l10n:keep agent tool result
                tasks.stopIfCurrent(owner, "用户在交还时选择了停止")
                Out(prefix + PhoneTasks.STOPPED_MESSAGE + "。", error = true, summary = ui.get("phone_log_handoff", "交还用户"), decision = "stopped") // l10n:keep test default
            }
            HandoffResult.TIMEOUT -> Out(
                // l10n:keep agent tool result
                prefix + "等了 10 分钟用户没有回应。停下来，告诉用户回来后可以接着做。",
                error = true,
                summary = ui.get("phone_log_handoff", "交还用户"), // l10n:keep test default
                decision = "timeout",
            )
        }
    }

    private fun stoppedOut(summary: String) = Out(PhoneTasks.STOPPED_MESSAGE + "。", error = true,
        summary = summary, decision = "stopped")

    companion object {
        /** Under DSH's 660 s MCP timeout, so the bridge always answers first. */
        const val MAX_TOTAL_MS = 640_000L
        const val PAUSE_WAIT_MS = 600_000L
        const val HANDOFF_MS = 600_000L

        /** Tools whose success means the agent got past whatever refused it before. */
        private val WRITES = setOf(PhoneToolCatalog.TAP, PhoneToolCatalog.TYPE, PhoneToolCatalog.TAP_XY, PhoneToolCatalog.OPEN)
        /** An uncertain effect call tightens draft eligibility; it does not prove input was dispatched. */
        private val TRACE_ACTIONS = setOf(PhoneToolCatalog.OPEN, PhoneToolCatalog.TAP, PhoneToolCatalog.TYPE,
            PhoneToolCatalog.SCROLL, PhoneToolCatalog.TAP_XY, PhoneToolCatalog.KEY)
        private val DONE = setOf("ok", "allowed", "confirmed", "confirmed-app", "confirmed-task")
        const val SETTLE_AFTER_LAUNCH_MS = 1200L
        const val MAX_APPS = 150
        const val MAX_COLLECT_CHARS = 16_000

        /** The call's own time, not counting waits for the person. */
        fun budgetMs(tool: String): Long = when (tool) {
            PhoneToolCatalog.APPS -> 15_000L
            PhoneToolCatalog.NOTIFY, PhoneToolCatalog.CLIPBOARD -> 10_000L
            PhoneToolCatalog.OPEN, PhoneToolCatalog.INTENT -> 25_000L
            PhoneToolCatalog.SCREEN -> 12_000L
            PhoneToolCatalog.COLLECT -> 120_000L
            PhoneToolCatalog.HANDOFF -> 30_000L
            else -> 30_000L
        }
    }
}
