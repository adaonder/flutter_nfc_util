package com.onderada.nfc_util

import android.nfc.NfcAdapter
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Unit tests for the parts of the Android side that are pure logic.
 *
 * The plugin class itself is not reachable from here: it needs an NfcAdapter, an Activity and
 * a live binary messenger, and there is no mocking framework on this target. Reader flags,
 * adapter states and error classification are the parts that can go wrong silently, so they
 * are the parts worth pinning down.
 */
class TagMapperTest {

  private fun config(
    pollingOptions: List<PollingOptionPigeon> = listOf(PollingOptionPigeon.ISO14443),
    noPlatformSounds: Boolean = false,
    skipNdefCheck: Boolean = false,
    discoverNfcBarcode: Boolean = false,
  ) = SessionConfigPigeon(
    pollingOptions = pollingOptions,
    alertMessage = null,
    invalidateAfterFirstRead = true,
    noPlatformSounds = noPlatformSounds,
    skipNdefCheck = skipNdefCheck,
    discoverNfcBarcode = discoverNfcBarcode,
    presenceCheckDelayMillis = 250,
  )

  @Test
  fun `iso14443 polls both A and B`() {
    // One option, two flags: the ISO 14443 family covers both type A and type B tags.
    assertEquals(
      NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B,
      TagMapper.readerFlags(config(listOf(PollingOptionPigeon.ISO14443))),
    )
  }

  @Test
  fun `each remaining polling option maps to one flag`() {
    assertEquals(NfcAdapter.FLAG_READER_NFC_V, TagMapper.readerFlags(config(listOf(PollingOptionPigeon.ISO15693))))
    assertEquals(NfcAdapter.FLAG_READER_NFC_F, TagMapper.readerFlags(config(listOf(PollingOptionPigeon.ISO18092))))
  }

  @Test
  fun `an empty polling set falls back to every technology`() {
    // Zero flags would start a session that can never discover anything, which looks to the
    // app exactly like a tag that is never presented.
    val expected = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or
      NfcAdapter.FLAG_READER_NFC_F or NfcAdapter.FLAG_READER_NFC_V
    assertEquals(expected, TagMapper.readerFlags(config(emptyList())))
  }

  @Test
  fun `session switches add their flags`() {
    val base = NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B

    assertEquals(
      base or NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS,
      TagMapper.readerFlags(config(noPlatformSounds = true)),
    )
    assertEquals(
      base or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
      TagMapper.readerFlags(config(skipNdefCheck = true)),
    )
    // Without this flag the platform never surfaces barcode tags at all, so NfcBarcode is
    // unreachable no matter what the rest of the API offers.
    assertEquals(
      base or NfcAdapter.FLAG_READER_NFC_BARCODE,
      TagMapper.readerFlags(config(discoverNfcBarcode = true)),
    )
  }

  @Test
  fun `the raw flag list maps every value`() {
    assertEquals(NfcAdapter.FLAG_READER_NFC_A, TagMapper.readerFlags(listOf(ReaderFlagPigeon.NFC_A)))
    assertEquals(NfcAdapter.FLAG_READER_NFC_B, TagMapper.readerFlags(listOf(ReaderFlagPigeon.NFC_B)))
    assertEquals(NfcAdapter.FLAG_READER_NFC_F, TagMapper.readerFlags(listOf(ReaderFlagPigeon.NFC_F)))
    assertEquals(NfcAdapter.FLAG_READER_NFC_V, TagMapper.readerFlags(listOf(ReaderFlagPigeon.NFC_V)))
    assertEquals(NfcAdapter.FLAG_READER_NFC_BARCODE, TagMapper.readerFlags(listOf(ReaderFlagPigeon.NFC_BARCODE)))
    assertEquals(
      NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS,
      TagMapper.readerFlags(listOf(ReaderFlagPigeon.NO_PLATFORM_SOUNDS)),
    )
    assertEquals(
      NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
      TagMapper.readerFlags(listOf(ReaderFlagPigeon.SKIP_NDEF_CHECK)),
    )
  }

  @Test
  fun `the raw flag list ORs its values together and honours an empty set`() {
    assertEquals(
      NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_V,
      TagMapper.readerFlags(listOf(ReaderFlagPigeon.NFC_A, ReaderFlagPigeon.NFC_V)),
    )
    // Unlike the cross-platform path there is no fallback here: the caller reached for the
    // raw escape hatch and gets exactly what it asked for.
    assertEquals(0, TagMapper.readerFlags(emptyList<ReaderFlagPigeon>()))
  }

  @Test
  fun `adapter states map to their wire values`() {
    assertEquals(AdapterStatePigeon.OFF, TagMapper.adapterState(NfcAdapter.STATE_OFF))
    assertEquals(AdapterStatePigeon.TURNING_ON, TagMapper.adapterState(NfcAdapter.STATE_TURNING_ON))
    assertEquals(AdapterStatePigeon.ON, TagMapper.adapterState(NfcAdapter.STATE_ON))
    assertEquals(AdapterStatePigeon.TURNING_OFF, TagMapper.adapterState(NfcAdapter.STATE_TURNING_OFF))
  }

  @Test
  fun `an unrecognised adapter state degrades rather than throwing`() {
    // The broadcast carries whatever the platform put in it; guessing wrong is better than
    // taking the process down from a receiver.
    assertEquals(AdapterStatePigeon.OFF, TagMapper.adapterState(9999))
  }

  @Test
  fun `throwables are classified into the typed codes`() {
    assertEquals(AndroidErrorCodePigeon.IO, TagMapper.errorCode(IOException("boom")))
    assertEquals(AndroidErrorCodePigeon.SECURITY, TagMapper.errorCode(SecurityException()))
    assertEquals(AndroidErrorCodePigeon.INVALID_PARAMETER, TagMapper.errorCode(IllegalArgumentException()))
    assertEquals(AndroidErrorCodePigeon.NOT_CONNECTED, TagMapper.errorCode(IllegalStateException()))
    assertEquals(AndroidErrorCodePigeon.UNSUPPORTED_TECH, TagMapper.errorCode(UnsupportedOperationException()))
  }

  @Test
  fun `an unclassified throwable becomes unknown rather than being dropped`() {
    assertEquals(AndroidErrorCodePigeon.UNKNOWN, TagMapper.errorCode(RuntimeException()))
    assertEquals(AndroidErrorCodePigeon.UNKNOWN, TagMapper.errorCode(Throwable()))
  }

  @Test
  fun `security is checked before io, since both can reach the same call`() {
    // SecurityException is not an IOException, so this only pins the intent: an
    // unauthenticated Mifare Classic sector must not be reported as a transport failure.
    assertEquals(AndroidErrorCodePigeon.SECURITY, TagMapper.errorCode(SecurityException("no auth")))
  }
}
