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
  fun `poll technologies OR together`() {
    assertEquals(
      NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_V,
      TagMapper.pollTechFlags(listOf(PollTechPigeon.NFC_A, PollTechPigeon.NFC_V)),
    )
    assertEquals(NfcAdapter.FLAG_READER_NFC_B, TagMapper.pollTechFlags(listOf(PollTechPigeon.NFC_B)))
    assertEquals(NfcAdapter.FLAG_READER_NFC_F, TagMapper.pollTechFlags(listOf(PollTechPigeon.NFC_F)))
  }

  @Test
  fun `an empty poll set disables polling rather than falling back`() {
    // The opposite of readerFlags, and deliberately so: reader mode with no flags is always
    // a mistake, while discovery technology with no flags is how an app turns polling off.
    assertEquals(NfcAdapter.FLAG_READER_DISABLE, TagMapper.pollTechFlags(emptyList()))
    assertEquals(NfcAdapter.FLAG_READER_DISABLE, TagMapper.pollTechFlags(listOf(PollTechPigeon.DISABLE)))
  }

  @Test
  fun `keep wins over any technology beside it`() {
    // FLAG_READER_KEEP is bit 31, not a technology bit, so OR-ing it with one would ask the
    // controller for something that has no meaning. Whichever way round they are listed, the
    // answer is the same.
    assertEquals(NfcAdapter.FLAG_READER_KEEP, TagMapper.pollTechFlags(listOf(PollTechPigeon.KEEP)))
    assertEquals(
      NfcAdapter.FLAG_READER_KEEP,
      TagMapper.pollTechFlags(listOf(PollTechPigeon.NFC_A, PollTechPigeon.KEEP)),
    )
    assertEquals(
      NfcAdapter.FLAG_LISTEN_KEEP,
      TagMapper.listenTechFlags(listOf(ListenTechPigeon.KEEP, ListenTechPigeon.NFC_B)),
    )
  }

  @Test
  fun `listen technologies map to the passive listen flags`() {
    assertEquals(NfcAdapter.FLAG_LISTEN_NFC_PASSIVE_A, TagMapper.listenTechFlags(listOf(ListenTechPigeon.NFC_A)))
    assertEquals(NfcAdapter.FLAG_LISTEN_NFC_PASSIVE_B, TagMapper.listenTechFlags(listOf(ListenTechPigeon.NFC_B)))
    assertEquals(NfcAdapter.FLAG_LISTEN_NFC_PASSIVE_F, TagMapper.listenTechFlags(listOf(ListenTechPigeon.NFC_F)))
    assertEquals(
      NfcAdapter.FLAG_LISTEN_NFC_PASSIVE_A or NfcAdapter.FLAG_LISTEN_NFC_PASSIVE_F,
      TagMapper.listenTechFlags(listOf(ListenTechPigeon.NFC_A, ListenTechPigeon.NFC_F)),
    )
    assertEquals(NfcAdapter.FLAG_LISTEN_DISABLE, TagMapper.listenTechFlags(emptyList()))
  }

  @Test
  fun `polling frame types map from their ASCII codes`() {
    // The platform spells these as the character codes of 'A', 'B', 'F', 'O' and 'X'. They
    // are pinned here because nothing else in the plugin would notice them being wrong: a
    // mislabelled frame is still a frame, and reaches the app looking plausible.
    assertEquals(PollingFrameTypePigeon.A, TagMapper.pollingFrameType('A'.code))
    assertEquals(PollingFrameTypePigeon.B, TagMapper.pollingFrameType('B'.code))
    assertEquals(PollingFrameTypePigeon.F, TagMapper.pollingFrameType('F'.code))
    assertEquals(PollingFrameTypePigeon.ON, TagMapper.pollingFrameType('O'.code))
    assertEquals(PollingFrameTypePigeon.OFF, TagMapper.pollingFrameType('X'.code))
    assertEquals(PollingFrameTypePigeon.UNKNOWN, TagMapper.pollingFrameType('U'.code))
  }

  @Test
  fun `an unrecognised polling frame type is reported rather than dropped`() {
    // A reader's proprietary probe is often exactly what an app registered a filter for, so
    // a type this release has no name for still has to arrive.
    assertEquals(PollingFrameTypePigeon.UNKNOWN, TagMapper.pollingFrameType(0))
    assertEquals(PollingFrameTypePigeon.UNKNOWN, TagMapper.pollingFrameType(9999))
  }

  @Test
  fun `internal error codes map, and an unknown one degrades`() {
    assertEquals(NfcInternalErrorPigeon.UNKNOWN, TagMapper.internalError(0))
    assertEquals(NfcInternalErrorPigeon.NFC_CRASH_RESTART, TagMapper.internalError(1))
    assertEquals(NfcInternalErrorPigeon.NFC_HARDWARE_ERROR, TagMapper.internalError(2))
    assertEquals(NfcInternalErrorPigeon.COMMAND_TIMEOUT, TagMapper.internalError(3))
    assertEquals(NfcInternalErrorPigeon.UNKNOWN, TagMapper.internalError(42))
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
