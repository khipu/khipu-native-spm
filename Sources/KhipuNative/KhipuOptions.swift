import Foundation

/// Options for `KhipuPayment.start`.
///
/// `primaryColor`, `fontFamily`, `skipExitPage`, `skipExitSuccessPage` and `webOptions` are passed to khipu's
/// payment page unchanged; the SDK does not validate them. `theme` is resolved to light or dark before it is sent.
/// `locale` is used only by the SDK and never reaches the payment page. The payment page's `modal`/`modalOptions`
/// are not offered: the SDK always shows the payment in its own full-screen UI.
public struct KhipuOptions {
    /// Color scheme: `.light` and `.dark` force one; `.auto` follows the device's dark-mode setting, read once
    /// when `KhipuPayment.start` is called and kept for the whole payment.
    public enum Theme {
        case light, dark, auto
    }

    /// The payment page's `primaryColor`, passed unchanged.
    public let primaryColor: String?
    /// The payment page's `fontFamily`, passed unchanged.
    public let fontFamily: String?
    /// The payment page's `skipExitPage`; `nil` leaves it unset, so the page's default applies.
    public let skipExitPage: Bool?
    /// The payment page's `skipExitSuccessPage`; `nil` leaves it unset, so the page's default applies.
    public let skipExitSuccessPage: Bool?
    /// Color scheme of the payment page and of the SDK's UI around it (background, status bar). See `Theme`.
    public let theme: Theme
    /// Additional payment-page options this type does not model, passed unchanged, so a new page option can be
    /// used without an SDK update. Empty means none are sent.
    public let webOptions: [String: String]
    /// BCP-47 locale for the texts the SDK itself produces: `KhipuPaymentError.message` and
    /// `KhipuPaymentError.hint`. `nil` (the default) means `es-CL`, the supported locale. `es-MX`, `es-AR` and
    /// `es-PE` are accepted but have no translations yet; any text a locale does not provide, including every
    /// text of an unrecognized locale, falls back to `es-CL`.
    ///
    /// The locale applies to errors reported by the payment page and to `PAYMENT_TIMEOUT`; other errors raised by
    /// the SDK are always in `es-CL`. It is never sent to the payment page, which handles its own localization.
    public let locale: String?

    public init(
        primaryColor: String? = nil,
        fontFamily: String? = nil,
        skipExitPage: Bool? = nil,
        skipExitSuccessPage: Bool? = nil,
        theme: Theme = .auto,
        webOptions: [String: String] = [:],
        locale: String? = nil
    ) {
        self.primaryColor = primaryColor
        self.fontFamily = fontFamily
        self.skipExitPage = skipExitPage
        self.skipExitSuccessPage = skipExitSuccessPage
        self.theme = theme
        self.webOptions = webOptions
        self.locale = locale
    }

    /// Options with every field at its default: no styling, `.auto` theme, no extra page options, `es-CL`.
    public static func `default`() -> KhipuOptions { KhipuOptions() }
}
