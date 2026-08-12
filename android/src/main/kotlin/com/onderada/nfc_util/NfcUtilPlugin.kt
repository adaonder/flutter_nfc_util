package com.onderada.nfc_util

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.cardemulation.CardEmulation
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcelable
import android.util.Log
import android.nfc.tech.IsoDep
import android.nfc.tech.MifareClassic
import android.nfc.tech.MifareUltralight
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.nfc.tech.NfcA
import android.nfc.tech.NfcB
import android.nfc.tech.NfcF
import android.nfc.tech.NfcV
import android.nfc.tech.TagTechnology
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class NfcUtilPlugin :
    FlutterPlugin,
    ActivityAware,
    NfcHostApi,
    NfcAndroidHostApi,
    HceBridge,
    PluginRegistry.NewIntentListener {

    private var flutterApi: NfcFlutterApi? = null
    private var activity: Activity? = null
    private var adapter: NfcAdapter? = null
    private var applicationContext: Context? = null

    /** Only touched from [ioExecutor], which is single-threaded. */
    private var connectedTech: TagTechnology? = null

    /** Written from the reader-mode callback thread, read from the platform thread. */
    private val tags: MutableMap<String, Tag> = ConcurrentHashMap()

    /**
     * Tag I/O blocks and must never run on the platform thread. Single-threaded so command
     * sequences that depend on connection state -- a Mifare Classic authenticate followed
     * by readBlock -- stay ordered on one connection.
     */
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * True while reader mode is on.
     *
     * 2.x let a second startSession silently replace the first, while iOS rejected it. Both
     * platforms now reject, so the same code behaves the same way on both.
     */
    private var sessionActive = false

    /** The tag whose intent launched the app, until something takes it. */
    private var pendingInitialTag: TagPigeon? = null

    private var foregroundDispatchEnabled = false

    /**
     * Registered against the *application* context so it survives a configuration change
     * without a deregister/register cycle. Non-null exactly while registered, which makes
     * both double-register and double-unregister impossible.
     */
    private var receiverContext: Context? = null

    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != NfcAdapter.ACTION_ADAPTER_STATE_CHANGED) return
            val state = TagMapper.adapterState(intent.getIntExtra(NfcAdapter.EXTRA_ADAPTER_STATE, NfcAdapter.STATE_OFF))
            // Posted rather than called from this binder thread: the channel is main-thread
            // only. mainHandler rather than activity.runOnUiThread, so a state change during
            // a configuration change is still delivered.
            mainHandler.post { flutterApi?.onAdapterStateChanged(state) {} }
        }
    }

    // ---------------------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        adapter = NfcAdapter.getDefaultAdapter(binding.applicationContext)
        flutterApi = NfcFlutterApi(binding.binaryMessenger)
        NfcHostApi.setUp(binding.binaryMessenger, this)
        NfcAndroidHostApi.setUp(binding.binaryMessenger, this)
        // The card emulation bridge is deliberately NOT claimed here. Every FlutterEngine
        // registers every plugin, including the background engines other plugins spin up for
        // push messages and scheduled work, so claiming on attach let an unrelated engine
        // take the APDU stream and then null it on teardown -- leaving emulation dead for the
        // engine actually on screen. It is claimed in hceRegisterAids instead: the engine
        // that asked to emulate a card is the one that answers for it.
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        teardownSession()
        unregisterAdapterStateReceiver()
        if (NfcUtilApduService.activeBridge === this) NfcUtilApduService.activeBridge = null
        NfcHostApi.setUp(binding.binaryMessenger, null)
        NfcAndroidHostApi.setUp(binding.binaryMessenger, null)
        flutterApi = null
        applicationContext = null
        ioExecutor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addOnNewIntentListener(this)
        registerAdapterStateReceiver(binding.activity.applicationContext)
        // The launching intent is only readable here; by the time Dart asks, the activity
        // may have been through a rebuild.
        captureTagFromIntent(binding.activity.intent, initial = true)
    }

    override fun onDetachedFromActivity() {
        teardownSession()
        unregisterAdapterStateReceiver()
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // Deliberately keeps the receiver: a reattach follows, and the registration is on
        // the application context anyway.
        teardownSession()
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        captureTagFromIntent(intent, initial = false)
        // Never claims the intent: other plugins and the app may want it too.
        return false
    }

    private fun registerAdapterStateReceiver(context: Context) {
        if (receiverContext != null) return
        val filter = IntentFilter(NfcAdapter.ACTION_ADAPTER_STATE_CHANGED)
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(adapterStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(adapterStateReceiver, filter)
            }
            receiverContext = context
        }
    }

    private fun unregisterAdapterStateReceiver() {
        val context = receiverContext ?: return
        receiverContext = null
        runCatching { context.unregisterReceiver(adapterStateReceiver) }
    }

    // ---------------------------------------------------------------------------------
    // NfcHostApi
    // ---------------------------------------------------------------------------------

    override fun checkAvailability(): AvailabilityPigeon {
        val adapter = adapter ?: return AvailabilityPigeon.UNSUPPORTED
        return if (adapter.isEnabled) AvailabilityPigeon.ENABLED else AvailabilityPigeon.DISABLED
    }

    override fun startSession(config: SessionConfigPigeon, callback: (Result<Unit>) -> Unit) {
        beginReaderMode(
            flags = TagMapper.readerFlags(config),
            presenceCheckDelayMillis = config.presenceCheckDelayMillis,
            skipNdef = config.skipNdefCheck,
            callback = callback,
        )
    }

    override fun stopSession(alertMessage: String?, errorMessage: String?, callback: (Result<Unit>) -> Unit) {
        // Both messages are iOS reader-sheet text and have no meaning here.
        teardownSession()
        callback(Result.success(Unit))
    }

    override fun disposeTag(handle: String) {
        val tag = tags.remove(handle) ?: return
        // Only drop the connection when it belongs to the tag being disposed: with a
        // continuous session a second tag can already be in flight.
        closeConnectedTech(onlyFor = tag)
    }

    override fun ndefRead(handle: String, callback: (Result<NdefMessagePigeon?>) -> Unit) {
        withTech(handle, Ndef::get, callback) { it.ndefMessage?.let(TagMapper::messageToWire) }
    }

    override fun ndefWrite(handle: String, message: NdefMessagePigeon, callback: (Result<Unit>) -> Unit) {
        withTech(handle, Ndef::get, callback) { it.writeNdefMessage(TagMapper.messageFromWire(message)) }
    }

    override fun ndefWriteLock(handle: String, callback: (Result<Unit>) -> Unit) {
        withTech(handle, Ndef::get, callback) { it.makeReadOnly() }
    }

    // ---------------------------------------------------------------------------------
    // NfcAndroidHostApi -- adapter
    // ---------------------------------------------------------------------------------

    override fun isEnabled(): Boolean = adapter?.isEnabled == true

    override fun isSecureNfcSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && adapter?.isSecureNfcSupported == true

    override fun isSecureNfcEnabled(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && adapter?.isSecureNfcEnabled == true

    override fun enableReaderMode(
        flags: List<ReaderFlagPigeon>,
        presenceCheckDelayMillis: Long,
        callback: (Result<Unit>) -> Unit,
    ) {
        beginReaderMode(
            flags = TagMapper.readerFlags(flags),
            presenceCheckDelayMillis = presenceCheckDelayMillis,
            skipNdef = flags.contains(ReaderFlagPigeon.SKIP_NDEF_CHECK),
            callback = callback,
        )
    }

    override fun disableReaderMode(callback: (Result<Unit>) -> Unit) {
        teardownSession()
        callback(Result.success(Unit))
    }

    private fun beginReaderMode(
        flags: Int,
        presenceCheckDelayMillis: Long,
        skipNdef: Boolean,
        callback: (Result<Unit>) -> Unit,
    ) {
        val adapter = adapter ?: return callback(failure("unavailable", "This device has no NFC adapter."))
        val activity = activity ?: return callback(failure("no_activity", "No activity is attached."))
        // Reader mode on a disabled adapter starts without error and then never discovers
        // anything, which is indistinguishable to the app from a tag never being presented.
        if (!adapter.isEnabled) {
            return callback(failure(AndroidErrorCodePigeon.ADAPTER_DISABLED, "NFC is switched off in system settings."))
        }
        if (sessionActive) {
            return callback(failure("session_already_exists", "A session is already running. Stop it first."))
        }

        // A longer presence-check interval keeps the controller from polling the tag as
        // aggressively, which saves power and leaves more airtime for our own commands.
        val extras = Bundle().apply {
            putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, presenceCheckDelayMillis.toInt())
        }

        try {
            adapter.enableReaderMode(activity, { tag -> onTagDiscovered(tag, skipNdef) }, flags, extras)
        } catch (e: Throwable) {
            Log.w(TAG, "enableReaderMode failed", e)
            return callback(failure("unavailable", "Reader mode could not be started: ${e.message}"))
        }

        sessionActive = true
        callback(Result.success(Unit))
    }

    /** Runs on a binder thread. An exception escaping here would take the process down. */
    private fun onTagDiscovered(tag: Tag, skipNdef: Boolean) {
        val handle = UUID.randomUUID().toString()
        val wire = try {
            TagMapper.toWire(tag, handle, skipNdef)
        } catch (e: Throwable) {
            Log.e(TAG, "could not read the discovered tag", e)
            // 2.x dropped this silently, which left an app watching a session that looked
            // alive but delivered nothing.
            reportError(TagMapper.errorCode(e), "Discovered tag could not be read: ${e.message}")
            return
        }

        tags[handle] = tag
        // The activity can go away between discovery and delivery, which would leave the
        // channel talking to a dead engine.
        mainHandler.post { flutterApi?.onDiscovered(wire) {} }
    }

    private fun teardownSession() {
        sessionActive = false
        activity?.let { runCatching { adapter?.disableReaderMode(it) } }
        closeConnectedTech()
        tags.clear()
    }

    /**
     * Reports a failure to Dart.
     *
     * [sessionEnded] is the difference between "start a new session" and "keep waiting". A
     * tag that cannot be read is a failure of that tag; reader mode is still polling, and a
     * caller that restarted here would be refused and go deaf.
     */
    private fun reportError(
        code: AndroidErrorCodePigeon,
        message: String,
        sessionEnded: Boolean = false,
    ) {
        mainHandler.post {
            flutterApi?.onError(
                SessionKindPigeon.TAG,
                NfcErrorPigeon(
                    source = ErrorSourcePigeon.ANDROID,
                    androidCode = code,
                    message = message,
                    sessionEnded = sessionEnded,
                ),
            ) {}
        }
    }

    // ---------------------------------------------------------------------------------
    // NfcAndroidHostApi -- foreground dispatch and intents
    // ---------------------------------------------------------------------------------

    override fun enableForegroundDispatch() {
        val adapter = adapter ?: return
        val activity = activity ?: return

        val intent = Intent(activity, activity.javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        // MUTABLE because the NFC system service fills the tag extras in before delivering.
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pendingIntent = PendingIntent.getActivity(activity, 0, intent, flags)

        runCatching {
            adapter.enableForegroundDispatch(activity, pendingIntent, null, null)
            foregroundDispatchEnabled = true
        }
    }

    override fun disableForegroundDispatch() {
        if (!foregroundDispatchEnabled) return
        foregroundDispatchEnabled = false
        activity?.let { runCatching { adapter?.disableForegroundDispatch(it) } }
    }

    override fun takeInitialTag(): TagPigeon? {
        val tag = pendingInitialTag
        // Consumed, so a widget rebuild cannot process the same tag twice.
        pendingInitialTag = null
        return tag
    }

    /**
     * Pulls a tag out of an NFC intent.
     *
     * Reader mode and intent delivery are separate channels: an app can use one, the other,
     * or both. When a session is running the tag also arrives through [onTagDiscovered],
     * so this only feeds the intent callback.
     */
    private fun captureTagFromIntent(intent: Intent?, initial: Boolean) {
        val action = intent?.action ?: return
        if (action != NfcAdapter.ACTION_NDEF_DISCOVERED &&
            action != NfcAdapter.ACTION_TECH_DISCOVERED &&
            action != NfcAdapter.ACTION_TAG_DISCOVERED
        ) {
            return
        }

        val tag = intentExtraTag(intent) ?: return
        val handle = UUID.randomUUID().toString()
        val wire = try {
            TagMapper.toWire(tag, handle, skipNdef = false)
        } catch (e: Throwable) {
            // Reported rather than dropped. This path has no session behind it, so an app that
            // never hears about the tap has nothing at all to go on.
            Log.e(TAG, "could not read a tag delivered by intent", e)
            reportError(TagMapper.errorCode(e), "Tag from intent could not be read: ${e.message}")
            return
        }

        // An NDEF intent already carries the message the system read, so a tag that has
        // since left the field still delivers its content.
        val fromIntent = intentExtraMessages(intent)
        val enriched = if (fromIntent != null && wire.ndefAndroid?.cachedMessage == null) {
            wire.copy(ndefAndroid = wire.ndefAndroid?.copy(cachedMessage = fromIntent))
        } else {
            wire
        }

        tags[handle] = tag
        if (initial) {
            pendingInitialTag = enriched
        } else {
            mainHandler.post { flutterApi?.onTagFromIntent(enriched) {} }
        }
    }

    @Suppress("DEPRECATION")
    private fun intentExtraTag(intent: Intent): Tag? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG, Tag::class.java)
        } else {
            intent.getParcelableExtra(NfcAdapter.EXTRA_TAG)
        }

    @Suppress("DEPRECATION")
    private fun intentExtraMessages(intent: Intent): NdefMessagePigeon? {
        val raw: Array<out Parcelable>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES, NdefMessage::class.java)
        } else {
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
        }
        val first = raw?.firstOrNull() as? NdefMessage ?: return null
        return runCatching { TagMapper.messageToWire(first) }.getOrNull()
    }

    // ---------------------------------------------------------------------------------
    // NfcAndroidHostApi -- tag I/O
    // ---------------------------------------------------------------------------------

    override fun transceive(
        handle: String,
        tech: AndroidTechPigeon,
        data: ByteArray,
        callback: (Result<ByteArray>) -> Unit,
    ) {
        when (tech) {
            AndroidTechPigeon.NFC_A -> withTech(handle, NfcA::get, callback) { it.transceive(data) }
            AndroidTechPigeon.NFC_B -> withTech(handle, NfcB::get, callback) { it.transceive(data) }
            AndroidTechPigeon.NFC_F -> withTech(handle, NfcF::get, callback) { it.transceive(data) }
            AndroidTechPigeon.NFC_V -> withTech(handle, NfcV::get, callback) { it.transceive(data) }
            AndroidTechPigeon.ISO_DEP -> withTech(handle, IsoDep::get, callback) { it.transceive(data) }
            AndroidTechPigeon.MIFARE_CLASSIC -> withTech(handle, MifareClassic::get, callback) { it.transceive(data) }
            AndroidTechPigeon.MIFARE_ULTRALIGHT ->
                withTech(handle, MifareUltralight::get, callback) { it.transceive(data) }
        }
    }

    /**
     * Both accessors read the technology's static description rather than talking to the
     * tag, so they run without a connection.
     *
     * Connecting here would be actively harmful, not merely wasteful: `connectTech` closes
     * whatever technology is currently connected when the class differs, and
     * `TagTechnology.close()` performs an RF reselect that wipes a MIFARE sector
     * authentication and any timeout already set. Asking a tag how long its packets may be,
     * between authenticating a sector and reading it, would silently undo the
     * authentication.
     */
    override fun getMaxTransceiveLength(handle: String, tech: AndroidTechPigeon, callback: (Result<Long>) -> Unit) {
        when (tech) {
            AndroidTechPigeon.NFC_A -> readOnly(handle, NfcA::get, callback) { it.maxTransceiveLength.toLong() }
            AndroidTechPigeon.NFC_B -> readOnly(handle, NfcB::get, callback) { it.maxTransceiveLength.toLong() }
            AndroidTechPigeon.NFC_F -> readOnly(handle, NfcF::get, callback) { it.maxTransceiveLength.toLong() }
            AndroidTechPigeon.NFC_V -> readOnly(handle, NfcV::get, callback) { it.maxTransceiveLength.toLong() }
            AndroidTechPigeon.ISO_DEP -> readOnly(handle, IsoDep::get, callback) { it.maxTransceiveLength.toLong() }
            AndroidTechPigeon.MIFARE_CLASSIC ->
                readOnly(handle, MifareClassic::get, callback) { it.maxTransceiveLength.toLong() }
            AndroidTechPigeon.MIFARE_ULTRALIGHT ->
                readOnly(handle, MifareUltralight::get, callback) { it.maxTransceiveLength.toLong() }
        }
    }

    override fun getTimeout(handle: String, tech: AndroidTechPigeon, callback: (Result<Long>) -> Unit) {
        // android.nfc.tech offers no timeout accessor for NfcB or NfcV, hence the gaps.
        when (tech) {
            AndroidTechPigeon.NFC_A -> readOnly(handle, NfcA::get, callback) { it.timeout.toLong() }
            AndroidTechPigeon.NFC_F -> readOnly(handle, NfcF::get, callback) { it.timeout.toLong() }
            AndroidTechPigeon.ISO_DEP -> readOnly(handle, IsoDep::get, callback) { it.timeout.toLong() }
            AndroidTechPigeon.MIFARE_CLASSIC -> readOnly(handle, MifareClassic::get, callback) { it.timeout.toLong() }
            AndroidTechPigeon.MIFARE_ULTRALIGHT ->
                readOnly(handle, MifareUltralight::get, callback) { it.timeout.toLong() }
            else -> callback(
                failure(AndroidErrorCodePigeon.UNSUPPORTED_TECH, "${tech.name} has no timeout accessor on Android."),
            )
        }
    }

    override fun setTimeout(handle: String, tech: AndroidTechPigeon, timeout: Long, callback: (Result<Unit>) -> Unit) {
        val millis = timeout.toInt()
        when (tech) {
            AndroidTechPigeon.NFC_A -> withTech(handle, NfcA::get, callback) { it.timeout = millis }
            AndroidTechPigeon.NFC_F -> withTech(handle, NfcF::get, callback) { it.timeout = millis }
            AndroidTechPigeon.ISO_DEP -> withTech(handle, IsoDep::get, callback) { it.timeout = millis }
            AndroidTechPigeon.MIFARE_CLASSIC -> withTech(handle, MifareClassic::get, callback) { it.timeout = millis }
            AndroidTechPigeon.MIFARE_ULTRALIGHT ->
                withTech(handle, MifareUltralight::get, callback) { it.timeout = millis }
            else -> callback(
                failure(AndroidErrorCodePigeon.UNSUPPORTED_TECH, "${tech.name} has no timeout accessor on Android."),
            )
        }
    }

    override fun mifareClassicAuthenticateSector(
        handle: String,
        sectorIndex: Long,
        key: ByteArray,
        useKeyA: Boolean,
        callback: (Result<Boolean>) -> Unit,
    ) {
        withTech(handle, MifareClassic::get, callback) {
            if (useKeyA) {
                it.authenticateSectorWithKeyA(sectorIndex.toInt(), key)
            } else {
                it.authenticateSectorWithKeyB(sectorIndex.toInt(), key)
            }
        }
    }

    override fun mifareClassicReadBlock(handle: String, blockIndex: Long, callback: (Result<ByteArray>) -> Unit) {
        withTech(handle, MifareClassic::get, callback) { it.readBlock(blockIndex.toInt()) }
    }

    override fun mifareClassicWriteBlock(
        handle: String,
        blockIndex: Long,
        data: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) {
        withTech(handle, MifareClassic::get, callback) { it.writeBlock(blockIndex.toInt(), data) }
    }

    override fun mifareClassicIncrement(
        handle: String,
        blockIndex: Long,
        value: Long,
        callback: (Result<Unit>) -> Unit,
    ) {
        withTech(handle, MifareClassic::get, callback) { it.increment(blockIndex.toInt(), value.toInt()) }
    }

    override fun mifareClassicDecrement(
        handle: String,
        blockIndex: Long,
        value: Long,
        callback: (Result<Unit>) -> Unit,
    ) {
        withTech(handle, MifareClassic::get, callback) { it.decrement(blockIndex.toInt(), value.toInt()) }
    }

    override fun mifareClassicRestore(handle: String, blockIndex: Long, callback: (Result<Unit>) -> Unit) {
        withTech(handle, MifareClassic::get, callback) { it.restore(blockIndex.toInt()) }
    }

    override fun mifareClassicTransfer(handle: String, blockIndex: Long, callback: (Result<Unit>) -> Unit) {
        withTech(handle, MifareClassic::get, callback) { it.transfer(blockIndex.toInt()) }
    }

    // Pure geometry over the card layout. Synchronous and connectionless: opening a
    // connection would turn a local computation into something that can fail with tag_lost.

    override fun mifareClassicBlockToSector(handle: String, blockIndex: Long): Long =
        geometry(handle) { it.blockToSector(blockIndex.toInt()).toLong() }

    override fun mifareClassicSectorToBlock(handle: String, sectorIndex: Long): Long =
        geometry(handle) { it.sectorToBlock(sectorIndex.toInt()).toLong() }

    override fun mifareClassicBlockCountInSector(handle: String, sectorIndex: Long): Long =
        geometry(handle) { it.getBlockCountInSector(sectorIndex.toInt()).toLong() }

    private fun geometry(handle: String, body: (MifareClassic) -> Long): Long {
        val tag = tags[handle] ?: throw FlutterErrorOf(wireName(AndroidErrorCodePigeon.INVALID_PARAMETER), "Tag is not found.")
        val tech = MifareClassic.get(tag)
            ?: throw FlutterErrorOf(wireName(AndroidErrorCodePigeon.UNSUPPORTED_TECH), "Tag is not a Mifare Classic.")
        return body(tech)
    }

    override fun mifareUltralightReadPages(handle: String, pageOffset: Long, callback: (Result<ByteArray>) -> Unit) {
        withTech(handle, MifareUltralight::get, callback) { it.readPages(pageOffset.toInt()) }
    }

    override fun mifareUltralightWritePage(
        handle: String,
        pageOffset: Long,
        data: ByteArray,
        callback: (Result<Unit>) -> Unit,
    ) {
        withTech(handle, MifareUltralight::get, callback) { it.writePage(pageOffset.toInt(), data) }
    }

    override fun ndefFormat(
        handle: String,
        firstMessage: NdefMessagePigeon,
        readOnly: Boolean,
        callback: (Result<Unit>) -> Unit,
    ) {
        withTech(handle, NdefFormatable::get, callback) {
            val message = TagMapper.messageFromWire(firstMessage)
            if (readOnly) it.formatReadOnly(message) else it.format(message)
        }
    }

    // ---------------------------------------------------------------------------------
    // NfcAndroidHostApi -- host card emulation
    // ---------------------------------------------------------------------------------

    override fun hceIsSupported(): Boolean =
        applicationContext?.packageManager?.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION) == true

    override fun hceRegisterAids(aids: List<String>, callback: (Result<Boolean>) -> Unit) {
        val emulation = cardEmulation() ?: return callback(failure("unavailable", "Card emulation is unavailable."))
        val component = apduServiceComponent() ?: return callback(failure("unavailable", "No application context."))

        // The service ships disabled so a reader-only app does not appear in the system's
        // card-emulation registry. Asking to register AIDs is the point at which the app has
        // said it wants to be a card.
        //
        // Enabling a component is persistent: it survives process death, reboot and app
        // update. So every path that does not end in a live registration has to put it back,
        // or a failed call would leave the app enrolled forever, answering other people's
        // readers with the placeholder AID.
        setApduServiceEnabled(true)

        val registered = runCatching { emulation.registerAidsForService(component, CardEmulation.CATEGORY_OTHER, aids) }
        registered.onFailure {
            setApduServiceEnabled(false)
            return callback(Result.failure(FlutterErrorOf("unavailable", it.message ?: "")))
        }

        if (!registered.getOrDefault(false)) {
            setApduServiceEnabled(false)
            return callback(Result.success(false))
        }

        // Claimed only once the app has actually opted into emulation, so a background engine
        // from an unrelated plugin cannot take the APDU stream from the engine on screen.
        NfcUtilApduService.activeBridge = this
        callback(Result.success(true))
    }

    override fun hceUnregisterAids(callback: (Result<Boolean>) -> Unit) {
        val emulation = cardEmulation() ?: return callback(failure("unavailable", "Card emulation is unavailable."))
        val component = apduServiceComponent() ?: return callback(failure("unavailable", "No application context."))

        if (NfcUtilApduService.activeBridge === this) NfcUtilApduService.activeBridge = null
        val removed = runCatching { emulation.removeAidsForService(component, CardEmulation.CATEGORY_OTHER) }
        // Back to invisible: the app is no longer offering to be a card.
        setApduServiceEnabled(false)
        callback(removed.fold({ Result.success(it) }, { Result.failure(FlutterErrorOf("unavailable", it.message ?: "")) }))
    }

    /**
     * Turns the emulation service on or off as a package component.
     *
     * `DONT_KILL_APP` because the alternative is restarting the very process that asked.
     */
    private fun setApduServiceEnabled(enabled: Boolean) {
        val context = applicationContext ?: return
        val component = apduServiceComponent() ?: return
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        runCatching { context.packageManager.setComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP) }
    }

    override fun hceRespond(response: ByteArray) {
        NfcUtilApduService.respond(response)
    }

    override fun hceSetPreferredService(preferred: Boolean) {
        val emulation = cardEmulation() ?: return
        val activity = activity ?: return
        val component = apduServiceComponent() ?: return
        runCatching {
            if (preferred) {
                emulation.setPreferredService(activity, component)
            } else {
                emulation.unsetPreferredService(activity)
            }
        }
    }

    private fun cardEmulation(): CardEmulation? = adapter?.let { runCatching { CardEmulation.getInstance(it) }.getOrNull() }

    private fun apduServiceComponent(): ComponentName? =
        applicationContext?.let { ComponentName(it, NfcUtilApduService::class.java) }

    override fun onApduReceived(apdu: ByteArray) {
        mainHandler.post { flutterApi?.onApduReceived(apdu) {} }
    }

    override fun onHceDeactivated(reason: Int) {
        mainHandler.post { flutterApi?.onHceDeactivated(reason.toLong()) {} }
    }

    // ---------------------------------------------------------------------------------
    // Tag plumbing
    // ---------------------------------------------------------------------------------

    /**
     * Resolves the handle and reads a value off the technology's static description, without
     * opening a connection.
     *
     * Synchronous on purpose: there is no I/O to keep off the platform thread, and routing
     * it through [ioExecutor] would only make it queue behind a tag exchange.
     */
    private fun <T : TagTechnology, R> readOnly(
        handle: String,
        techFactory: (Tag) -> T?,
        callback: (Result<R>) -> Unit,
        body: (T) -> R,
    ) {
        val tag = tags[handle]
            ?: return callback(failure(AndroidErrorCodePigeon.INVALID_PARAMETER, "Tag is not found."))
        val tech = techFactory(tag)
            ?: return callback(
                failure(AndroidErrorCodePigeon.UNSUPPORTED_TECH, "Tag does not answer to the requested technology."),
            )

        callback(
            runCatching { body(tech) }
                .fold({ Result.success(it) }, { Result.failure(FlutterErrorOf(wireName(TagMapper.errorCode(it)), it.message ?: "")) }),
        )
    }

    /**
     * Resolves the handle, connects the requested technology on [ioExecutor], and posts the
     * outcome back to the platform thread.
     */
    private fun <T : TagTechnology, R> withTech(
        handle: String,
        techFactory: (Tag) -> T?,
        callback: (Result<R>) -> Unit,
        body: (T) -> R,
    ) {
        val tag = tags[handle]
            ?: return callback(failure(AndroidErrorCodePigeon.INVALID_PARAMETER, "Tag is not found."))

        ioExecutor.execute {
            val tech = try {
                connectTech(tag, techFactory)
            } catch (e: Throwable) {
                Log.w(TAG, "connect failed", e)
                mainHandler.post {
                    callback(failure(TagMapper.errorCode(e), "connect: ${e.javaClass.simpleName}: ${e.message}"))
                }
                return@execute
            }

            if (tech == null) {
                mainHandler.post {
                    callback(failure(AndroidErrorCodePigeon.UNSUPPORTED_TECH, "Tag does not answer to the requested technology."))
                }
                return@execute
            }

            try {
                val value = body(tech)
                mainHandler.post { callback(Result.success(value)) }
            } catch (e: Throwable) {
                Log.w(TAG, "tag operation failed", e)
                mainHandler.post {
                    callback(failure(TagMapper.errorCode(e), "${e.javaClass.simpleName}: ${e.message}"))
                }
            }
        }
    }

    /**
     * Reuses the connected technology when it targets the same tag and class.
     *
     * Reconnecting would drop state the following commands depend on: a Mifare Classic
     * sector authentication only holds for the connection it was made on.
     */
    @Suppress("UNCHECKED_CAST")
    private fun <T : TagTechnology> connectTech(tag: Tag, techFactory: (Tag) -> T?): T? {
        val tech = techFactory(tag) ?: return null
        val current = connectedTech

        if (current != null &&
            current.javaClass == tech.javaClass &&
            current.tag === tag &&
            runCatching { current.isConnected }.getOrDefault(false)
        ) {
            return current as T
        }

        if (current != null) {
            connectedTech = null
            runCatching { current.close() }
        }

        tech.connect()
        connectedTech = tech
        return tech
    }

    private fun closeConnectedTech(onlyFor: Tag? = null) {
        // Runs on ioExecutor so connectedTech stays single-threaded.
        ioExecutor.execute {
            val tech = connectedTech ?: return@execute
            if (onlyFor != null && tech.tag !== onlyFor) return@execute
            connectedTech = null
            runCatching { tech.close() }
        }
    }

    private fun <T> failure(code: String, message: String): Result<T> = Result.failure(FlutterErrorOf(code, message))

    private fun <T> failure(code: AndroidErrorCodePigeon, message: String): Result<T> =
        Result.failure(FlutterErrorOf(wireName(code), message))

    private companion object {
        const val TAG = "NfcUtilPlugin"
    }
}

/** A [FlutterError] with the fields filled in, since the generated constructor is positional. */
private fun FlutterErrorOf(code: String, message: String) = FlutterError(code, message, null)

/**
 * The code a PlatformException carries for a typed failure.
 *
 * Spelled exactly like the Dart enum value so `NfcAndroidErrorCode.values.byName(e.code)`
 * resolves it. The Kotlin enum is SCREAMING_CASE and the Dart one is camelCase, so this
 * cannot be `.name`, and lowercasing produced a third spelling that matched neither.
 */
private fun wireName(code: AndroidErrorCodePigeon): String = when (code) {
    AndroidErrorCodePigeon.TAG_LOST -> "tagLost"
    AndroidErrorCodePigeon.IO -> "io"
    AndroidErrorCodePigeon.SECURITY -> "security"
    AndroidErrorCodePigeon.UNSUPPORTED_TECH -> "unsupportedTech"
    AndroidErrorCodePigeon.NOT_CONNECTED -> "notConnected"
    AndroidErrorCodePigeon.ADAPTER_DISABLED -> "adapterDisabled"
    AndroidErrorCodePigeon.INVALID_PARAMETER -> "invalidParameter"
    AndroidErrorCodePigeon.UNKNOWN -> "unknown"
}
