import Foundation
import BridgeGenerated

/// Native wrapper around the GENERATED, pure `translate()`. It mints a fresh `debug_id` (via `DebugId`) so the
/// produced `KhipuPaymentError` is self-contained, and — for an envelope code with NO public mapping — emits
/// `bridge.untranslated_error` through the `TelemetrySink` seam (warn) with the unmapped `{ raw_code }` (NEVER a
/// `correlation_id`). The generated layer stays free of the SDK's RNG + TelemetrySink (those live here); this is
/// the only place the untranslated signal is acted on.
///
/// The SAME split for i18n: the generated resolver falls back to es-CL PURELY, and THIS seam turns the pure
/// miss-detection (`missingTranslationKeys`, a key-set membership check) into one `i18n.missing_translation` per
/// missed key ({ key, requested_locale, resolved_locale } — no caller identifiers).
///
/// Injected `telemetry`/`debugId` so tests are deterministic. Takes no lock, and the payment coordinator calls it
/// outside its own lock, so its telemetry is never emitted while a lock is held. Mirrors `PublicErrorTranslator.kt`.
final class PublicErrorTranslator {
    private let telemetry: TelemetrySink
    private let debugId: DebugId

    init(telemetry: TelemetrySink = NoopTelemetrySink(), debugId: DebugId = DebugId()) {
        self.telemetry = telemetry
        self.debugId = debugId
    }

    /// Translate an envelope `envelopeCode` (+ optional upstream `rawCode` from `BridgeError.raw_code`) to
    /// the public error the merchant app receives. Unknown code → INTERNAL_ERROR, with `raw_code` preserved
    /// internally and exactly one `bridge.untranslated_error`. Returns the full `ErrorTranslation` (error + internal
    /// raw_code).
    ///
    /// `locale` comes from `KhipuOptions.locale` (BCP-47); nil → es-CL. A key the requested locale does not serve
    /// resolves from es-CL and emits `i18n.missing_translation`.
    func translateError(envelopeCode: String, rawCode: String? = nil, locale: String? = nil) -> ErrorTranslation {
        let result = translate(envelopeCode: envelopeCode, rawCode: rawCode, debugId: debugId.generate(), locale: locale)
        if result.untranslated {
            // untranslated ⇒ result.rawCode is non-nil (translate sets it to rawCode ?? envelopeCode).
            telemetry.emit(event: TelemetryEvent.untranslatedError, fields: ["raw_code": result.rawCode ?? envelopeCode])
        }
        // One event per missed key. Only a beta/unknown locale can miss (the i18n coverage gate keeps production
        // locales complete; nil/es-CL short-circuits to empty inside the generated check).
        for key in missingTranslationKeys(result.error.code, locale: locale) {
            telemetry.emit(event: TelemetryEvent.i18nMissingTranslation, fields: [
                "key": key,
                // Raw (un-normalized) but CAPPED: the only fully caller-chosen field in the registry —
                // never ride an unbounded merchant string into telemetry.
                "requested_locale": String((locale ?? KhipuI18n.defaultLocale).prefix(64)),
                "resolved_locale": KhipuI18n.defaultLocale,
            ])
        }
        return result
    }
}
