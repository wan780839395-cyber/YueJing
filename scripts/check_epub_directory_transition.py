"""Source-level transition contracts, not Swift/WKWebView/UI execution."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
web = (ROOT / 'App/EPUB/EPUBWebView.swift').read_text(encoding='utf-8')
model = (ROOT / 'App/EPUB/EPUBReaderViewModel.swift').read_text(encoding='utf-8')
checks = []
failures = []


def require(condition, label):
    (checks if condition else failures).append(label)


def between(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0] if start in source else ''


ready = between(web, '            runtimeTrace.record(.locatorReady)', '        if payload.kind == .error')
ack = between(web, '    func acknowledgePresentation(for token:', '    /// Reject a current presentation')
require('transitionSnapshot?.removeFromSuperview()' not in ready,
        'locator ready does not uncover the transition before business readiness')
require('readinessTask?.cancel()' not in ready and 'if transitionSnapshot == nil' not in ready,
        'the original deadline remains live with or without a snapshot until acknowledgement')
require('activeRequest?.token == token, readyToken == token' in ack,
        'acknowledgement requires current full token and final locator readiness')
require('transitionSnapshot?.removeFromSuperview()' in ack and 'readinessTask?.cancel()' in ack,
        'accepted acknowledgement releases the cover and existing deadline')
require('readyToken != token || pendingPresentationToken == token' in web,
        'existing deadline can still fail a ready but unacknowledged transition without relying on snapshot success')
require('case preparing, navigating, rebasing, configuring, restoringWindow, awaitingPresentation, ready' in web,
        'diagnostic stage distinguishes business acknowledgement from DOM restore')
require('try await Task.sleep(for: .seconds(15))' in web,
        'readiness deadline is not enlarged')
confirmed = between(model, '                    guard marked else', '                    if let started = self.openingStarted')
require('guard self.webView.controller?.acknowledgePresentation(for: expectedToken) != false' in confirmed and
        confirmed.find('acknowledgePresentation(for:') < confirmed.index('self.currentPosition = position') and
        'await ' not in confirmed,
        'after gated markReady, accepted presentation and ready publication share one non-suspending main-actor turn')
error = between(model, '        case .error:', '        case .ready:')
require('generation = UUID()' in error and 'currentToken = nil' in error,
        'locator error synchronously invalidates queued markReady and late ready')
require('self.webView.controller?.rejectPresentation(for: expectedToken)' in model and
        'webView.controller?.rejectPresentation(for: token)' in model,
        'invalid position and failed current business readiness release/revoke presentation')
require('!request.preserveViewport, loadedDocumentPath != nil, transitionSnapshot == nil' in web and
        'transitionSnapshot.isUserInteractionEnabled = false' in web,
        'natural promotion stays uncovered and snapshots cannot intercept controls')
require('payload.sessionID == current.token.sessionID' in web and 'payload.epoch == current.token.epoch' in web and
        'self.generation == gen' in model and 'self.currentToken == expectedToken' in model,
        'session epoch generation and current-token rejection remain')
print(json.dumps({'passed': not failures, 'checks': checks, 'failures': failures,
                  'native_executed': 0, 'swift_compiled': False, 'device_verified': False}, ensure_ascii=False, indent=2))
raise SystemExit(bool(failures))
