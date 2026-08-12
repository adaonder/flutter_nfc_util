// Translation between the generated wire types and the public API.
//
// Every mapper is an exhaustive `switch` rather than an index or name lookup. That costs a
// few lines over `Public.values[wire.index]`, and buys the one thing those cannot give: the
// analyzer fails the build when a value is added on one side and not the other.
//
// The failure mode this avoids is real and quiet. A name or index lookup compiles happily
// while the two enums drift, and then throws at run time on the first device new enough to
// report the value that was only added on one side -- so it surfaces as a crash in the
// field, on exactly the hardware that is hardest to test against.

import 'ndef/message.dart';
import 'ndef/record.dart';
import 'common.dart';
import 'pigeon.g.dart';

NfcAvailability availabilityFromWire(AvailabilityPigeon value) => switch (value) {
  AvailabilityPigeon.enabled => NfcAvailability.enabled,
  AvailabilityPigeon.disabled => NfcAvailability.disabled,
  AvailabilityPigeon.unsupported => NfcAvailability.unsupported,
};

PollingOptionPigeon pollingOptionToWire(NfcPollingOption value) => switch (value) {
  NfcPollingOption.iso14443 => PollingOptionPigeon.iso14443,
  NfcPollingOption.iso15693 => PollingOptionPigeon.iso15693,
  NfcPollingOption.iso18092 => PollingOptionPigeon.iso18092,
};

NfcAdapterState adapterStateFromWire(AdapterStatePigeon value) => switch (value) {
  AdapterStatePigeon.off => NfcAdapterState.off,
  AdapterStatePigeon.turningOn => NfcAdapterState.turningOn,
  AdapterStatePigeon.on => NfcAdapterState.on,
  AdapterStatePigeon.turningOff => NfcAdapterState.turningOff,
};

NfcError errorFromWire(NfcErrorPigeon value) => NfcError(
  source: switch (value.source) {
    ErrorSourcePigeon.android => NfcErrorSource.android,
    ErrorSourcePigeon.ios => NfcErrorSource.ios,
  },
  message: value.message,
  sessionEnded: value.sessionEnded,
  iosCode: value.iosCode == null ? null : readerErrorCodeFromWire(value.iosCode!),
  androidCode: value.androidCode == null ? null : androidErrorCodeFromWire(value.androidCode!),
);

NfcAndroidErrorCode androidErrorCodeFromWire(AndroidErrorCodePigeon value) => switch (value) {
  AndroidErrorCodePigeon.tagLost => NfcAndroidErrorCode.tagLost,
  AndroidErrorCodePigeon.io => NfcAndroidErrorCode.io,
  AndroidErrorCodePigeon.security => NfcAndroidErrorCode.security,
  AndroidErrorCodePigeon.unsupportedTech => NfcAndroidErrorCode.unsupportedTech,
  AndroidErrorCodePigeon.notConnected => NfcAndroidErrorCode.notConnected,
  AndroidErrorCodePigeon.adapterDisabled => NfcAndroidErrorCode.adapterDisabled,
  AndroidErrorCodePigeon.invalidParameter => NfcAndroidErrorCode.invalidParameter,
  AndroidErrorCodePigeon.unknown => NfcAndroidErrorCode.unknown,
};

NfcReaderErrorCode readerErrorCodeFromWire(ReaderErrorCodePigeon value) => switch (value) {
  ReaderErrorCodePigeon.firstNdefTagRead => NfcReaderErrorCode.firstNdefTagRead,
  ReaderErrorCodePigeon.sessionTerminatedUnexpectedly => NfcReaderErrorCode.sessionTerminatedUnexpectedly,
  ReaderErrorCodePigeon.sessionTimeout => NfcReaderErrorCode.sessionTimeout,
  ReaderErrorCodePigeon.systemIsBusy => NfcReaderErrorCode.systemIsBusy,
  ReaderErrorCodePigeon.userCanceled => NfcReaderErrorCode.userCanceled,
  ReaderErrorCodePigeon.tagNotWritable => NfcReaderErrorCode.tagNotWritable,
  ReaderErrorCodePigeon.tagSizeTooSmall => NfcReaderErrorCode.tagSizeTooSmall,
  ReaderErrorCodePigeon.tagUpdateFailure => NfcReaderErrorCode.tagUpdateFailure,
  ReaderErrorCodePigeon.zeroLengthMessage => NfcReaderErrorCode.zeroLengthMessage,
  ReaderErrorCodePigeon.retryExceeded => NfcReaderErrorCode.retryExceeded,
  ReaderErrorCodePigeon.tagConnectionLost => NfcReaderErrorCode.tagConnectionLost,
  ReaderErrorCodePigeon.tagNotConnected => NfcReaderErrorCode.tagNotConnected,
  ReaderErrorCodePigeon.tagResponseError => NfcReaderErrorCode.tagResponseError,
  ReaderErrorCodePigeon.sessionInvalidated => NfcReaderErrorCode.sessionInvalidated,
  ReaderErrorCodePigeon.packetTooLong => NfcReaderErrorCode.packetTooLong,
  ReaderErrorCodePigeon.invalidParameters => NfcReaderErrorCode.invalidParameters,
  ReaderErrorCodePigeon.unsupportedFeature => NfcReaderErrorCode.unsupportedFeature,
  ReaderErrorCodePigeon.invalidParameter => NfcReaderErrorCode.invalidParameter,
  ReaderErrorCodePigeon.invalidParameterLength => NfcReaderErrorCode.invalidParameterLength,
  ReaderErrorCodePigeon.parameterOutOfBound => NfcReaderErrorCode.parameterOutOfBound,
  ReaderErrorCodePigeon.radioDisabled => NfcReaderErrorCode.radioDisabled,
  ReaderErrorCodePigeon.securityViolation => NfcReaderErrorCode.securityViolation,
  ReaderErrorCodePigeon.ineligible => NfcReaderErrorCode.ineligible,
  ReaderErrorCodePigeon.accessNotAccepted => NfcReaderErrorCode.accessNotAccepted,
  ReaderErrorCodePigeon.unknown => NfcReaderErrorCode.unknown,
};

NdefTypeNameFormat typeNameFormatFromWire(TypeNameFormatPigeon value) => switch (value) {
  TypeNameFormatPigeon.empty => NdefTypeNameFormat.empty,
  TypeNameFormatPigeon.wellKnown => NdefTypeNameFormat.wellKnown,
  TypeNameFormatPigeon.media => NdefTypeNameFormat.media,
  TypeNameFormatPigeon.absoluteUri => NdefTypeNameFormat.absoluteUri,
  TypeNameFormatPigeon.external => NdefTypeNameFormat.external,
  TypeNameFormatPigeon.unknown => NdefTypeNameFormat.unknown,
  TypeNameFormatPigeon.unchanged => NdefTypeNameFormat.unchanged,
};

TypeNameFormatPigeon typeNameFormatToWire(NdefTypeNameFormat value) => switch (value) {
  NdefTypeNameFormat.empty => TypeNameFormatPigeon.empty,
  NdefTypeNameFormat.wellKnown => TypeNameFormatPigeon.wellKnown,
  NdefTypeNameFormat.media => TypeNameFormatPigeon.media,
  NdefTypeNameFormat.absoluteUri => TypeNameFormatPigeon.absoluteUri,
  NdefTypeNameFormat.external => TypeNameFormatPigeon.external,
  NdefTypeNameFormat.unknown => TypeNameFormatPigeon.unknown,
  NdefTypeNameFormat.unchanged => TypeNameFormatPigeon.unchanged,
};

NdefMessage ndefMessageFromWire(NdefMessagePigeon value) => NdefMessage([
  // fromParts, not the validating constructor: a tag may legitimately hold a shape the
  // creation rules reject, and refusing to represent it would turn a readable tag into an
  // exception.
  for (final record in value.records)
    NdefRecord.fromParts(
      typeNameFormat: typeNameFormatFromWire(record.typeNameFormat),
      type: record.type,
      identifier: record.identifier,
      payload: record.payload,
    ),
]);

NdefMessagePigeon ndefMessageToWire(NdefMessage value) => NdefMessagePigeon(
  records: [
    for (final record in value.records)
      NdefRecordPigeon(
        typeNameFormat: typeNameFormatToWire(record.typeNameFormat),
        type: record.type,
        identifier: record.identifier,
        payload: record.payload,
      ),
  ],
);
