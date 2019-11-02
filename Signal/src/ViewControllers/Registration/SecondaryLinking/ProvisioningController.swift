//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

@objc
public class ProvisioningController: NSObject {

    // MARK: - Dependencies

    var accountManager: AccountManager {
        return AppEnvironment.shared.accountManager
    }

    // MARK: -

    let onboardingController: OnboardingController
    let provisioningCipher: ProvisioningCipher

    let provisioningSocket: ProvisioningSocket

    var deviceIdPromise: Promise<String>
    var deviceIdResolver: Resolver<String>

    var provisionEnvelopePromise: Promise<ProvisioningProtoProvisionEnvelope>
    var provisionEnvelopeResolver: Resolver<ProvisioningProtoProvisionEnvelope>

    public init(onboardingController: OnboardingController) {
        self.onboardingController = onboardingController
        provisioningCipher = ProvisioningCipher.generate()

        (self.deviceIdPromise, self.deviceIdResolver) = Promise.pending()
        (self.provisionEnvelopePromise, self.provisionEnvelopeResolver) = Promise.pending()

        provisioningSocket = ProvisioningSocket()

        super.init()

        provisioningSocket.delegate = self
    }

    public func resetPromises() {
        (self.deviceIdPromise, self.deviceIdResolver) = Promise.pending()
        (self.provisionEnvelopePromise, self.provisionEnvelopeResolver) = Promise.pending()
    }

    @objc
    public static func presentRelinkingFlow() {
        let provisioningController = ProvisioningController(onboardingController: OnboardingController())
        let vc = SecondaryLinkingQRCodeViewController(provisioningController: provisioningController)
        let navController = OWSNavigationController(rootViewController: vc)
        provisioningController.awaitProvisioning(from: vc)
        navController.isNavigationBarHidden = true
        CurrentAppContext().mainWindow?.rootViewController = navController
    }

    // MARK: -

    func didConfirmSecondaryDevice(from viewController: SecondaryLinkingPrepViewController) {
        guard let navigationController = viewController.navigationController else {
            owsFailDebug("navigationController was unexpectedly nil")
            return
        }

        let qrCodeViewController = SecondaryLinkingQRCodeViewController(provisioningController: self)
        navigationController.pushViewController(qrCodeViewController, animated: true)

        awaitProvisioning(from: qrCodeViewController)
    }

    func awaitProvisioning(from viewController: SecondaryLinkingQRCodeViewController) {
        guard let navigationController = viewController.navigationController else {
            owsFailDebug("navigationController was unexpectedly nil")
            return
        }

        awaitProvisionMessage.done { [weak self, weak navigationController] message in
            guard let self = self else { throw PMKError.cancelled }
            guard let navigationController = navigationController else { throw PMKError.cancelled }

            // Verify the primary device is new enough to link us. Right now this is a simple check
            // of >= the latest version, but when we bump the version we may need to be more specific
            // if we have some backwards compatible support and allow a limited linking with an old
            // version of the app.
            guard let provisioningVersion = message.provisioningVersion,
                provisioningVersion >= OWSProvisioningVersion else {
                    OWSActionSheets.showActionSheet(
                        title: NSLocalizedString("SECONDARY_LINKING_ERROR_OLD_VERSION_TITLE",
                                                 comment: "alert title for outdated linking device"),
                        message: NSLocalizedString("SECONDARY_LINKING_ERROR_OLD_VERSION_MESSAGE",
                                                   comment: "alert message for outdated linking device")
                    ) { _ in
                        self.resetPromises()
                        navigationController.popViewController(animated: true)
                    }
                return
            }

            let confirmVC = SecondaryLinkingSetDeviceNameViewController(provisioningController: self)
            navigationController.pushViewController(confirmVC, animated: true)
        }.catch { error in
            switch error {
            case PMKError.cancelled:
                Logger.info("cancelled")
            default:
                Logger.warn("error: \(error)")
                let alert = ActionSheetController(title: NSLocalizedString("SECONDARY_LINKING_ERROR_WAITING_FOR_SCAN", comment: "alert title"),
                                                  message: error.localizedDescription)
                alert.addAction(ActionSheetAction(title: CommonStrings.retryButton,
                                                  accessibilityIdentifier: "alert.retry",
                                                  style: .default,
                                                  handler: { _ in
                                                    self.resetPromises()
                                                    navigationController.popViewController(animated: true)
                }))
                navigationController.presentActionSheet(alert)
            }
        }.retainUntilComplete()
    }

    func didSetDeviceName(_ deviceName: String, from viewController: UIViewController) {
        let backgroundBlock: (ModalActivityIndicatorViewController) -> Void = { modal in
            self.completeLinking(deviceName: deviceName).done {
                modal.dismiss {
                    self.onboardingController.linkingDidComplete(from: viewController)
                }
            }.catch { error in
                Logger.warn("error: \(error)")
                let alert = ActionSheetController(title: NSLocalizedString("SECONDARY_LINKING_ERROR_WAITING_FOR_SCAN", comment: "alert title"),
                                              message: error.localizedDescription)
                alert.addAction(ActionSheetAction(title: CommonStrings.retryButton,
                                              accessibilityIdentifier: "alert.retry",
                                              style: .default,
                                              handler: { _ in
                                                self.didSetDeviceName(deviceName, from: viewController)
                }))
                modal.dismiss {
                    viewController.presentActionSheet(alert)
                }
            }.retainUntilComplete()
        }

        ModalActivityIndicatorViewController.present(fromViewController: viewController,
                                                     canCancel: false,
                                                     backgroundBlock: backgroundBlock)
    }

    public func getProvisioningURL() -> Promise<URL> {
        return getDeviceId().map { [weak self] deviceId in
            guard let self = self else { throw PMKError.cancelled }

            return try self.buildProvisioningUrl(deviceId: deviceId)
        }
    }

    public var awaitProvisionMessage: Promise<ProvisionMessage> {
        return provisionEnvelopePromise.map { [weak self] envelope in
            guard let self = self else { throw PMKError.cancelled }
            return try self.provisioningCipher.decrypt(envelope: envelope)
        }
    }

    public let awaitContactAndGroupSync: Promise<Void> = when(fulfilled: [
        NotificationCenter.default.observe(once: .IncomingContactSyncDidComplete).asVoid(),
        NotificationCenter.default.observe(once: .IncomingGroupSyncDidComplete).asVoid()
    ])

    public func completeLinking(deviceName: String) -> Promise<Void> {
        return awaitProvisionMessage.then { [weak self] provisionMessage -> Promise<Void> in
            guard let self = self else { throw PMKError.cancelled }

            return self.accountManager.completeSecondaryLinking(provisionMessage: provisionMessage,
                                                                deviceName: deviceName)
        }.then { _ -> Promise<Void> in
            BenchEventStart(title: "waiting for initial contact and group sync", eventId: "initial-contact-sync")

            // we wait a bit for the initial group and contact syncs to come in before
            // proceeding to the inbox because we want to present the inbox already
            // populated with groups and contacts, rather than have the trickle in moments later.
            return self.awaitContactAndGroupSync.timeout(seconds: 20, substituteValue: ())
        }.done { _ -> Void in
            BenchEventComplete(eventId: "initial-contact-sync")
        }
    }

    // MARK: -

    private func buildProvisioningUrl(deviceId: String) throws -> URL {
        let base64PubKey: String = provisioningCipher.secondaryDevicePublicKey.serialized.base64EncodedString()

        var urlComponents = URLComponents()
        urlComponents.scheme = "tsdevice"
        urlComponents.queryItems = [
            URLQueryItem(name: "uuid", value: deviceId),
            URLQueryItem(name: "pub_key", value: base64PubKey)
        ]

        guard let url = urlComponents.url else {
            throw OWSAssertionError("invalid urlComponents: \(urlComponents)")
        }

        return url
    }

    private func getDeviceId() -> Promise<String> {
        assert(provisioningSocket.state != .open)
        // TODO send Keep-Alive or ping frames at regular intervals
        // iOS uses ping frames elsewhere, but moxie seemed surprised we weren't
        // using the keepalive endpoint. Waiting to here back from him before proceeding.
        // (If it's sufficient, my preference would be to do like we do elsewhere and
        // use the ping frames)
        provisioningSocket.connect()
        return deviceIdPromise
    }
}

extension ProvisioningController: ProvisioningSocketDelegate {
    public func provisioningSocket(_ provisioningSocket: ProvisioningSocket, didReceiveDeviceId deviceId: String) {
        assert(deviceIdPromise.isPending)
        deviceIdResolver.fulfill(deviceId)
    }

    public func provisioningSocket(_ provisioningSocket: ProvisioningSocket, didReceiveEnvelope envelope: ProvisioningProtoProvisionEnvelope) {
        // After receiving the provisioning message, there's nothing else to retreive from the provisioning socket
        provisioningSocket.disconnect()

        assert(provisionEnvelopePromise.isPending)
        return provisionEnvelopeResolver.fulfill(envelope)
    }

    public func provisioningSocket(_ provisioningSocket: ProvisioningSocket, didError error: Error) {
        deviceIdResolver.reject(error)
        provisionEnvelopeResolver.reject(error)
    }
}
