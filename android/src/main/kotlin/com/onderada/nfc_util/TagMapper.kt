package com.onderada.nfc_util

import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.IsoDep
import android.nfc.tech.MifareClassic
import android.nfc.tech.MifareUltralight
import android.nfc.tech.Ndef
import android.nfc.tech.NdefFormatable
import android.nfc.tech.NfcA
import android.nfc.tech.NfcB
import android.nfc.tech.NfcBarcode
import android.nfc.tech.NfcF
import android.nfc.tech.NfcV
import java.io.IOException

/**
 * Converts between `android.nfc` types and the generated wire types.
 *
 * This replaces the hand-written translator the 2.x line carried on both sides of the
 * channel. What is left here is only what Pigeon cannot do: reading the platform's own
 * objects.
 */
internal object TagMapper {

    /** Builds the wire tag, reading every technology the tag answers to. */
    fun toWire(tag: Tag, handle: String, skipNdef: Boolean): TagPigeon {
        val techList = tag.techList.map { it.substringAfterLast('.') }

        return TagPigeon(
            handle = handle,
            id = tag.id,
            techList = techList,
            ndefAndroid = if (skipNdef) null else Ndef.get(tag)?.let(::ndefToWire),
            // NdefFormatable has no state worth reporting; whether the tag answers to it is
            // the whole fact.
            ndefFormatable = NdefFormatable.get(tag) != null,
            nfcA = NfcA.get(tag)?.let {
                NfcAPigeon(
                    atqa = it.atqa,
                    sak = it.sak.toLong(),
                    maxTransceiveLength = it.maxTransceiveLength.toLong(),
                    timeout = it.timeout.toLong(),
                )
            },
            nfcB = NfcB.get(tag)?.let {
                NfcBPigeon(
                    applicationData = it.applicationData,
                    protocolInfo = it.protocolInfo,
                    maxTransceiveLength = it.maxTransceiveLength.toLong(),
                )
            },
            nfcF = NfcF.get(tag)?.let {
                NfcFPigeon(
                    manufacturer = it.manufacturer,
                    systemCode = it.systemCode,
                    maxTransceiveLength = it.maxTransceiveLength.toLong(),
                    timeout = it.timeout.toLong(),
                )
            },
            nfcV = NfcV.get(tag)?.let {
                NfcVPigeon(
                    dsfId = it.dsfId.toLong(),
                    responseFlags = it.responseFlags.toLong(),
                    maxTransceiveLength = it.maxTransceiveLength.toLong(),
                )
            },
            isoDep = IsoDep.get(tag)?.let {
                IsoDepPigeon(
                    hiLayerResponse = it.hiLayerResponse,
                    historicalBytes = it.historicalBytes,
                    isExtendedLengthApduSupported = it.isExtendedLengthApduSupported,
                    maxTransceiveLength = it.maxTransceiveLength.toLong(),
                    timeout = it.timeout.toLong(),
                )
            },
            mifareClassic = MifareClassic.get(tag)?.let {
                MifareClassicPigeon(
                    type = when (it.type) {
                        MifareClassic.TYPE_CLASSIC -> MifareClassicTypePigeon.CLASSIC
                        MifareClassic.TYPE_PLUS -> MifareClassicTypePigeon.PLUS
                        MifareClassic.TYPE_PRO -> MifareClassicTypePigeon.PRO
                        else -> MifareClassicTypePigeon.UNKNOWN
                    },
                    blockCount = it.blockCount.toLong(),
                    sectorCount = it.sectorCount.toLong(),
                    size = it.size.toLong(),
                    maxTransceiveLength = it.maxTransceiveLength.toLong(),
                    timeout = it.timeout.toLong(),
                )
            },
            mifareUltralight = MifareUltralight.get(tag)?.let {
                MifareUltralightPigeon(
                    type = when (it.type) {
                        MifareUltralight.TYPE_ULTRALIGHT -> MifareUltralightTypePigeon.ULTRALIGHT
                        MifareUltralight.TYPE_ULTRALIGHT_C -> MifareUltralightTypePigeon.ULTRALIGHT_C
                        else -> MifareUltralightTypePigeon.UNKNOWN
                    },
                    maxTransceiveLength = it.maxTransceiveLength.toLong(),
                    timeout = it.timeout.toLong(),
                )
            },
            nfcBarcode = NfcBarcode.get(tag)?.let {
                NfcBarcodePigeon(
                    type = when (it.type) {
                        NfcBarcode.TYPE_KOVIO -> NfcBarcodeTypePigeon.KOVIO
                        else -> NfcBarcodeTypePigeon.UNKNOWN
                    },
                    barcode = it.barcode,
                )
            },
        )
    }

    private fun ndefToWire(ndef: Ndef) = NdefAndroidPigeon(
        type = ndef.type,
        maxSize = ndef.maxSize.toLong(),
        isWritable = ndef.isWritable,
        canMakeReadOnly = ndef.canMakeReadOnly(),
        cachedMessage = ndef.cachedNdefMessage?.let(::messageToWire),
    )

    fun messageToWire(message: NdefMessage) = NdefMessagePigeon(
        records = message.records.map { record ->
            NdefRecordPigeon(
                typeNameFormat = when (record.tnf) {
                    NdefRecord.TNF_EMPTY -> TypeNameFormatPigeon.EMPTY
                    NdefRecord.TNF_WELL_KNOWN -> TypeNameFormatPigeon.WELL_KNOWN
                    NdefRecord.TNF_MIME_MEDIA -> TypeNameFormatPigeon.MEDIA
                    NdefRecord.TNF_ABSOLUTE_URI -> TypeNameFormatPigeon.ABSOLUTE_URI
                    NdefRecord.TNF_EXTERNAL_TYPE -> TypeNameFormatPigeon.EXTERNAL
                    NdefRecord.TNF_UNCHANGED -> TypeNameFormatPigeon.UNCHANGED
                    else -> TypeNameFormatPigeon.UNKNOWN
                },
                type = record.type,
                identifier = record.id,
                payload = record.payload,
            )
        },
    )

    fun messageFromWire(message: NdefMessagePigeon): NdefMessage = NdefMessage(
        message.records.map { record ->
            NdefRecord(
                when (record.typeNameFormat) {
                    TypeNameFormatPigeon.EMPTY -> NdefRecord.TNF_EMPTY
                    TypeNameFormatPigeon.WELL_KNOWN -> NdefRecord.TNF_WELL_KNOWN
                    TypeNameFormatPigeon.MEDIA -> NdefRecord.TNF_MIME_MEDIA
                    TypeNameFormatPigeon.ABSOLUTE_URI -> NdefRecord.TNF_ABSOLUTE_URI
                    TypeNameFormatPigeon.EXTERNAL -> NdefRecord.TNF_EXTERNAL_TYPE
                    TypeNameFormatPigeon.UNKNOWN -> NdefRecord.TNF_UNKNOWN
                    TypeNameFormatPigeon.UNCHANGED -> NdefRecord.TNF_UNCHANGED
                },
                record.type,
                record.identifier,
                record.payload,
            )
        }.toTypedArray(),
    )

    /** Reader-mode flags for the cross-platform session configuration. */
    fun readerFlags(config: SessionConfigPigeon): Int {
        var flags = 0
        for (option in config.pollingOptions) {
            flags = flags or when (option) {
                PollingOptionPigeon.ISO14443 -> NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B
                PollingOptionPigeon.ISO15693 -> NfcAdapter.FLAG_READER_NFC_V
                PollingOptionPigeon.ISO18092 -> NfcAdapter.FLAG_READER_NFC_F
            }
        }
        // An empty or unrecognised set would otherwise start a session that can never
        // discover anything.
        if (flags == 0) {
            flags = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or
                NfcAdapter.FLAG_READER_NFC_F or NfcAdapter.FLAG_READER_NFC_V
        }
        if (config.noPlatformSounds) flags = flags or NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        if (config.skipNdefCheck) flags = flags or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        if (config.discoverNfcBarcode) flags = flags or NfcAdapter.FLAG_READER_NFC_BARCODE
        return flags
    }

    /** Reader-mode flags for the raw Android escape hatch. */
    fun readerFlags(flags: List<ReaderFlagPigeon>): Int = flags.fold(0) { acc, flag ->
        acc or when (flag) {
            ReaderFlagPigeon.NFC_A -> NfcAdapter.FLAG_READER_NFC_A
            ReaderFlagPigeon.NFC_B -> NfcAdapter.FLAG_READER_NFC_B
            ReaderFlagPigeon.NFC_F -> NfcAdapter.FLAG_READER_NFC_F
            ReaderFlagPigeon.NFC_V -> NfcAdapter.FLAG_READER_NFC_V
            ReaderFlagPigeon.NFC_BARCODE -> NfcAdapter.FLAG_READER_NFC_BARCODE
            ReaderFlagPigeon.NO_PLATFORM_SOUNDS -> NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
            ReaderFlagPigeon.SKIP_NDEF_CHECK -> NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        }
    }

    fun adapterState(state: Int): AdapterStatePigeon = when (state) {
        NfcAdapter.STATE_OFF -> AdapterStatePigeon.OFF
        NfcAdapter.STATE_TURNING_ON -> AdapterStatePigeon.TURNING_ON
        NfcAdapter.STATE_ON -> AdapterStatePigeon.ON
        NfcAdapter.STATE_TURNING_OFF -> AdapterStatePigeon.TURNING_OFF
        else -> AdapterStatePigeon.OFF
    }

    /**
     * Classifies a throwable into the typed code the Dart side reports.
     *
     * 2.x reported four bare strings here, which left "the tag moved" and "the tag refused
     * the command" indistinguishable -- and those call for opposite responses from an app.
     */
    fun errorCode(e: Throwable): AndroidErrorCodePigeon = when (e) {
        is TagLostException -> AndroidErrorCodePigeon.TAG_LOST
        is SecurityException -> AndroidErrorCodePigeon.SECURITY
        is IOException -> AndroidErrorCodePigeon.IO
        is IllegalArgumentException -> AndroidErrorCodePigeon.INVALID_PARAMETER
        is IllegalStateException -> AndroidErrorCodePigeon.NOT_CONNECTED
        is UnsupportedOperationException -> AndroidErrorCodePigeon.UNSUPPORTED_TECH
        else -> AndroidErrorCodePigeon.UNKNOWN
    }
}
