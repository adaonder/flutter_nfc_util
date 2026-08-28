package com.onderada.nfc_util

import android.nfc.cardemulation.HostApduService
import android.nfc.cardemulation.PollingFrame
import android.os.Bundle
import android.util.Log

/**
 * What the plugin exposes to the emulation service.
 *
 * The service is an Android component with its own lifecycle: the system can start it
 * while nothing else of the app is running. Keeping the coupling to this one interface is
 * what makes that survivable -- when no plugin is attached there is simply no bridge, and
 * the service answers on its own.
 */
internal interface HceBridge {
    /** Called on a binder thread. Implementations must hop to the main thread themselves. */
    fun onApduReceived(apdu: ByteArray)

    fun onHceDeactivated(reason: Int)

    /**
     * Polling frames seen while observe mode is on. Also called on a binder thread.
     *
     * Already converted to the wire type: keeping `android.nfc.cardemulation.PollingFrame`
     * out of this interface's signatures is what lets the bridge be loaded unchanged on the
     * API 24 devices this plugin still supports, where that class does not exist.
     */
    fun onPollingFrames(frames: List<PollingFramePigeon>)
}

/**
 * Answers a contactless reader as if the phone were a card.
 *
 * The AIDs this responds to are registered at run time by
 * `HostCardEmulation.registerAids`, so an app does not have to ship a fixed list in its
 * manifest. The placeholder group in `nfc_util_apduservice.xml` exists only because
 * Android requires a service to declare at least one group before dynamic registration is
 * allowed; no reader selects it.
 */
class NfcUtilApduService : HostApduService() {

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray? {
        val bridge = activeBridge
        // No engine attached: the app is not running, so nothing can compose an answer.
        // Telling the reader so immediately is better than making it wait for a timeout.
        if (bridge == null || commandApdu == null) return SW_INSTRUCTION_NOT_SUPPORTED

        activeService = this
        bridge.onApduReceived(commandApdu)

        // Null means "the answer comes later", via sendResponseApdu. That is the whole
        // point: the round trip to Dart and back cannot happen inside this call.
        return null
    }

    override fun onDeactivated(reason: Int) {
        if (activeService === this) activeService = null
        activeBridge?.onHceDeactivated(reason)
    }

    /**
     * Reader polling frames, delivered instead of APDUs while observe mode is on.
     *
     * Only ever called on API 35 and above -- the base class has no such method below it --
     * so the `PollingFrame` reference in the body is safe. Generic erasure keeps it out of
     * the method descriptor, so the class still verifies on older devices.
     */
    override fun processPollingFrames(frames: MutableList<PollingFrame>) {
        val bridge = activeBridge ?: return
        activeService = this
        bridge.onPollingFrames(frames.map(TagMapper::pollingFrame))
    }

    /**
     * The system can tear this component down without an [onDeactivated] first -- there is no
     * reader exchange to end when the service is simply stopped -- so the static reference has
     * to be dropped here as well, or [respond] keeps addressing an instance the framework has
     * already let go of.
     */
    override fun onDestroy() {
        if (activeService === this) activeService = null
        super.onDestroy()
    }

    internal companion object {
        private const val TAG = "NfcUtilPlugin"

        /** `6D00`: the card does not support the requested instruction. */
        val SW_INSTRUCTION_NOT_SUPPORTED = byteArrayOf(0x6D, 0x00)

        /**
         * Set while a plugin is attached to an engine, cleared on detach.
         *
         * Volatile because the service reads it from a binder thread while the plugin
         * writes it from the main thread.
         */
        @Volatile
        var activeBridge: HceBridge? = null

        /** The instance currently in a reader exchange, if any. */
        @Volatile
        var activeService: NfcUtilApduService? = null

        /**
         * Sends a deferred answer for the APDU most recently delivered.
         *
         * Wrapped, like every other platform call this plugin makes. `sendResponseApdu` writes
         * to a Messenger the framework only hands over with a command APDU, so an answer that
         * arrives without one -- Dart responding to a polling frame while observe mode is on,
         * or answering after the link already dropped -- throws out of a Pigeon handler that
         * does not catch, which takes the process down. A response nobody is waiting for is
         * worth a log line, not a crash.
         */
        fun respond(response: ByteArray) {
            val service = activeService ?: return
            runCatching { service.sendResponseApdu(response) }
                .onFailure { Log.w(TAG, "response not delivered; no reader exchange is open", it) }
        }
    }
}
