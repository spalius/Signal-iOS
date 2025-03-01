//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

enum CVCBottomViewType: Equatable {
    // For perf reasons, we don't use a bottom view until
    // the view is about to appear for the first time.
    case none
    case inputToolbar
    case memberRequestView
    case messageRequestView(messageRequestType: MessageRequestType)
    case search
    case selection
    case blockingGroupMigration
}

// MARK: -

public extension ConversationViewController {

    internal var bottomViewType: CVCBottomViewType {
        get { viewState.bottomViewType }
        set {
            // For perf reasons, we avoid adding any "bottom view"
            // to the view hierarchy until its necessary, e.g. when
            // the view is about to appear.
            owsAssertDebug(hasViewWillAppearEverBegun)

            if viewState.bottomViewType != newValue {
                if viewState.bottomViewType == .inputToolbar {
                    // Dismiss the keyboard if we're swapping out the input toolbar
                    dismissKeyBoard()
                }
                viewState.bottomViewType = newValue
                updateBottomBar()
            }
        }
    }

    @objc
    func ensureBottomViewType() {
        AssertIsOnMainThread()

        guard viewState.selectionAnimationState == .idle else {
            return
        }

        bottomViewType = { () -> CVCBottomViewType in
            // The ordering of this method determines
            // precendence of the bottom views.

            if !hasViewWillAppearEverBegun {
                return .none
            } else if threadViewModel.hasPendingMessageRequest {
                let messageRequestType = Self.databaseStorage.read { transaction in
                    MessageRequestView.messageRequestType(forThread: self.threadViewModel.threadRecord,
                                                          transaction: transaction)
                }
                return .messageRequestView(messageRequestType: messageRequestType)
            } else if isLocalUserRequestingMember {
                return .memberRequestView
            } else if hasBlockingGroupMigration {
                return .blockingGroupMigration
            } else {
                switch uiMode {
                case .search:
                    return .search
                case .selection:
                    return .selection
                case .normal:
                    if viewState.isInPreviewPlatter || userLeftGroup {
                        return .none
                    } else {
                        return .inputToolbar
                    }
                }
            }
        }()
    }

    private func updateBottomBar() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            return
        }

        // Animate the dismissal of any existing request view.
        dismissRequestView()

        requestView?.removeFromSuperview()
        requestView = nil

        let bottomView: UIView?
        switch bottomViewType {
        case .none:
            bottomView = nil
        case .messageRequestView:
            let messageRequestView = MessageRequestView(threadViewModel: threadViewModel)
            messageRequestView.delegate = self
            requestView = messageRequestView
            bottomView = messageRequestView
        case .memberRequestView:
            let memberRequestView = MemberRequestView(threadViewModel: threadViewModel,
                                                      fromViewController: self)
            memberRequestView.delegate = self
            requestView = memberRequestView
            bottomView = memberRequestView
        case .search:
            bottomView = searchController.resultsBar
        case .selection:
            bottomView = selectionToolbar
        case .inputToolbar:
            bottomView = inputToolbar
        case .blockingGroupMigration:
            let migrationView = BlockingGroupMigrationView(threadViewModel: threadViewModel,
                                                           fromViewController: self)
            requestView = migrationView
            bottomView = migrationView
        }

        for subView in bottomBar.subviews {
            subView.removeFromSuperview()
        }

        if let newBottomView = bottomView {
            bottomBar.addSubview(newBottomView)

            // The request views expect to extend into the safe area.
            if requestView != nil {
                newBottomView.autoPinEdgesToSuperviewEdges()
            } else {
                newBottomView.autoPinEdgesToSuperviewMargins()
            }
        }

        updateInputAccessoryPlaceholderHeight()
        updateBottomBarPosition()
        updateContentInsets(animated: hasAppearedAndHasAppliedFirstLoad)
    }

    // This is expensive. We only need to do it if conversationStyle has changed.
    //
    // TODO: Once conversationStyle is immutable, compare the old and new
    //       conversationStyle values and exit early if it hasn't changed.
    @objc
    func updateInputToolbar() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            return
        }

        var messageDraft: MessageBody?
        var voiceMemoDraft: VoiceMessageModel?
        if let oldInputToolbar = self.inputToolbar {
            // Maintain draft continuity.
            messageDraft = oldInputToolbar.messageBody()
            voiceMemoDraft = oldInputToolbar.voiceMemoDraft
        } else {
            Self.databaseStorage.read { transaction in
                messageDraft = self.thread.currentDraft(with: transaction)
                if VoiceMessageModel.hasDraft(for: self.thread, transaction: transaction) {
                    voiceMemoDraft = VoiceMessageModel(thread: self.thread)
                }
            }
        }

        let newInputToolbar = buildInputToolbar(conversationStyle: conversationStyle,
                                                messageDraft: messageDraft,
                                                voiceMemoDraft: voiceMemoDraft)

        self.inputToolbar = newInputToolbar

        newInputToolbar.updateFontSizes()

        updateBottomBar()
    }

    @objc
    func reloadDraft() {
        AssertIsOnMainThread()

        guard let messageDraft = (Self.databaseStorage.read { transaction in
            self.thread.currentDraft(with: transaction)
        }) else {
            return
        }
        guard let inputToolbar = self.inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }
        inputToolbar.setMessageBody(messageDraft, animated: false)
    }

    @objc
    func updateBottomBarPosition() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            return
        }

        if let interactivePopGestureRecognizer = navigationController?.interactivePopGestureRecognizer {
            // Don't update the bottom bar position if an interactive pop is in progress
            switch interactivePopGestureRecognizer.state {
            case .possible, .failed:
                break
            default:
                return
            }
        }

        guard let bottomBarBottomConstraint = bottomBarBottomConstraint,
              let bottomBarSuperview = bottomBar.superview else {
            return
        }
        let bottomBarPosition = -inputAccessoryPlaceholder.keyboardOverlap
        let didChange = bottomBarBottomConstraint.constant != bottomBarPosition
        guard didChange else {
            return
        }
        bottomBarBottomConstraint.constant = bottomBarPosition

        // We always want to apply the new bottom bar position immediately,
        // as this only happens during animations (interactive or otherwise)
        bottomBarSuperview.layoutIfNeeded()
    }

    @objc
    func updateInputAccessoryPlaceholderHeight() {
        AssertIsOnMainThread()

        // If we're currently dismissing interactively, skip updating the
        // input accessory height. Changing it while dismissing can lead to
        // an infinite loop of keyboard frame changes as the listeners in
        // InputAcessoryViewPlaceholder will end up calling back here if
        // a dismissal is in progress.
        if isDismissingInteractively {
            return
        }

        // Apply any pending layout changes to ensure we're measuring the up-to-date height.
        bottomBar.superview?.layoutIfNeeded()

        inputAccessoryPlaceholder.desiredHeight = bottomBar.height
    }

    // MARK: - Message Request

    @objc
    func showMessageRequestDialogIfRequiredAsync() {
        AssertIsOnMainThread()

        DispatchQueue.main.async { [weak self] in
            self?.showMessageRequestDialogIfRequired()
        }
    }

    @objc
    func showMessageRequestDialogIfRequired() {
        AssertIsOnMainThread()

        ensureBottomViewType()
    }

    @objc
    func updateInputToolbarLayout() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            return
        }
        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        inputToolbar.updateLayout(withSafeAreaInsets: view.safeAreaInsets)
    }

    @objc
    func popKeyBoard() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        inputToolbar.beginEditingMessage()
    }

    @objc
    func dismissKeyBoard() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }

        guard viewState.selectionAnimationState == .idle else {
            return
        }

        guard let inputToolbar = inputToolbar else {
            owsFailDebug("Missing inputToolbar.")
            return
        }

        inputToolbar.endEditingMessage()
        inputToolbar.clearDesiredKeyboard()
    }

    private func dismissRequestView() {
        AssertIsOnMainThread()

        guard let requestView = self.requestView else {
            return
        }

        // Slide the request view off the bottom of the screen.
        let bottomInset: CGFloat = view.safeAreaInsets.bottom

        let dismissingView = requestView
        self.requestView = nil

        // Add the view on top of the new bottom bar (if there is one),
        // and then slide it off screen to reveal the new input view.
        view.addSubview(dismissingView)
        dismissingView.autoPinWidthToSuperview()
        dismissingView.autoPinEdge(toSuperviewEdge: .bottom)

        var endFrame = dismissingView.bounds
        endFrame.origin.y -= endFrame.size.height + bottomInset

        UIView.animate(withDuration: 0.2, delay: 0, options: []) {
            dismissingView.bounds = endFrame
        } completion: { (_) in
            dismissingView.removeFromSuperview()
        }
    }

    private var isLocalUserRequestingMember: Bool {
        guard let groupThread = thread as? TSGroupThread else {
            return false
        }
        return groupThread.isLocalUserRequestingMember
    }

    @objc
    var userLeftGroup: Bool {
        guard let groupThread = thread as? TSGroupThread else {
            return false
        }
        return !groupThread.isLocalUserFullMember
    }

    private var hasBlockingGroupMigration: Bool {
        thread.isBlockedByMigration
    }
}
