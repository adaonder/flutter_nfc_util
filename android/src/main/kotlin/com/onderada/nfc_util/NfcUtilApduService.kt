package com.onderada.nfc_util

import android.nfc.cardemulation.HostApduService
import android.os.Bundle

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

    internal companion object {
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

        /** Sends a deferred answer for the APDU most recently delivered. */
        fun respond(response: ByteArray) {
            activeService?.sendResponseApdu(response)
        }
    }
}
