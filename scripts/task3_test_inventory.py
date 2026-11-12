"""Reviewed Task3 case identities, not inferred from native pass counts.

The excluded performance baseline is inventoried too. Inventory drift is an error;
this module never rewrites the expected list from source or execution results.
"""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
# Each file belongs to exactly one execution group. Names are frozen review input.
FILES = {
    "TXTCoreTests/TXTChapterTests.swift": """wholeLineHeadingsPreservePreambleAndOriginalBytes proseAndLongLinesAreNotSilentlyTurnedIntoHeadings consecutiveAndTerminalHeadingsHaveNoEmptyPhantomSection""",
    "TXTCoreTests/TXTEncodingTests.swift": """autoDetectsASCIIUTF8AndGBCompatibleText gb18030FourByteScalarSurvivesEveryChunkSplit utf16BOMEndianAndSurrogatePairsAreStrict ambiguousBytesRequireExplicitChoiceWithPreview malformedBytesNeverBecomeReplacementCharacters documentIdentityPreservesSourceAndVersionMeaning gbkConversionStagesSeparateLegacyIdentifierFromCP936 gbkKnownMappingsPreserveStrictRoundTripAcrossChunks gbkAmbiguityPreviewRetainsExplicitChoice gbkRejectsMalformedAndGB18030OnlySequences""",
    "TXTCoreTests/TXTMappingTests.swift": """utf8ChunkBoundariesAndNewlinesKeepExactCoordinates emptyAndBOMOnlyDocumentsHaveOneContentBoundary rangesRejectInvalidBoundariesAndOverflow utf8BOMIsExcludedAndCombiningScalarsAreNotComposed""",
    "TXTCoreTests/TXTPaginationTests.swift": """nativeCoreTextPagesAdvanceAndCoverEveryUTF16Unit invalidOrUnusableGeometryFailsInsteadOfLooping""",
    "TXTCoreTests/TXTStorageTests.swift": """utf8CheckpointsKeepMixedScalarAndCRLFBoundariesAcrossChunks utf16CheckpointsPreserveSurrogatesAndFourByteCRLFSteps gbCheckpointsKeepStrictScalarWidthsAndNormalizedNewlines streamingVersionHashKeepsExistingByteSequenceForEveryEncoding automaticCandidatesDiscardLateFailuresAndCompareBeyondPreview streamedChapterLinesPreserveBlankLinesAndTerminalHeading""",
    "TXTCoreTests/TXTBlockDecoderTests.swift": """mixedGBWidthsNewlinesAndTinyChunksMatchFrozenScalarDecoder malformedAndTruncatedGBSequencesKeepEncodingAndFirstAbsoluteOffset anEarlierMappingFailureIsNotHiddenByALaterStructuralFailure unicodeBOMSurrogatesAutomaticChoicesAndInvalidChunksRemainIdentical canonicalBlocksReduceConverterCallsWithoutChangingAnyCoordinateOrVersion largeAndTinyInputBlocksKeepTheHardBoundAndScalarReference""",
    "ReaderDomainTests/DecodeTimingSummaryTests.swift": """fixedEncodingAndNestedTimingsDoNotClaimSeparateUnicodeCostsOrExposeText""",
    "ReaderDomainTests/DerivedBookFormatTests.swift": """fiveStrictEncodingsRoundTripCoordinatesBOMNewlinesAndPagedChapters crossChecksumPagesCheckpointsAndLongParagraphsKeepGlobalCoordinates globalGraphemesIncludeLongRegionalIndicatorRunsAndMultiPageClusters strictUTF16HandlesNonzeroDataIndicesAndRejectsUnpairedSurrogates malformedAuthenticatedHeaderLengthsOverlapsAndSchemaAreRejectedBeforeAllocation everyPayloadSectionDetectsBitChangesEvenWhenUTF16StillLooksValid truncatedFilesAndCorruptDigestTablesInvalidateAndPermitOneExplicitRebuild queryBudgetsAndInvalidBoundariesDoNotDestroyAValidGeneration fileReadsRejectOversizedOverflowAndPastEOFRequestsBeforeReserving""",
    "ReaderDomainTests/DerivedBookPublicationTests.swift": """v2DatabaseUpgradePreservesExistingBookVersionAndProgressAndEnablesDerivedPointers existingDefaultImportAndReaderDoNotCreateDerivedPackages diskReopenWithNewStoreKeepsVersionAndSavedProgressWithoutAFullDocumentAPI completeSourceSHARejectsSameSizeChangesAtBeginningMiddleEndAndMissingOriginal wrongStoredVersionNeverRewritesBookOrProgressToMatchANewPackage writeSpaceAndPublicationFaultsPreserveThePreviouslyCommittedGeneration cancellationBeforePublishAbortsButAfterCommitReturnsCommittedTruth staleCASCannotOverwriteOrInvalidateNewPointerAndLeasesProtectOldReaders concurrentExplicitBuildersLeaveOneUsableCurrentGeneration recoveryRemovesRecognizedInterruptedArtifactsAndHandlesCacheLossWithoutDeletingUserState artifactAndAggregateAdmissionBudgetsNeverEvictTheValidBookOrPointer""",
    "ReaderDomainTests/DerivedReadingIntegrationTests.swift": """productImportReusesItsDocumentEvenWhenTheLegacyMemoryCacheIsDisabled aNewServiceReusesDiskWithFreshSessionsLatestSettingsAndPosition aLegacyBookMigratesOnceAndTheProductPathDropsTheLegacyFullDocumentCache boundedWindowsMatchTheOriginalEngineAcrossPagesChaptersAndSettings directoryPagesAndChapterJumpsUseStableGlobalCoordinates aPathologicalClusterKeepsTheOldLayoutFailureAndDoesNotWriteAFakeStart aCachedProductOpenStillRejectsChangedAndMissingOriginals corruptPagesCloseTheirLeaseAndAnExplicitNewOpenRebuildsWithoutLosingProgress derivedAdmissionFailureLeavesImportedTruthAndReliableProgressIntact cancellationAfterOriginalCommitStillReturnsTheCommittedImport memoryPressureDropsOnlyPagesAndKeepsTheActiveSessionUsable productCacheReclaimsUnleasedOldPackagesButNeverTheActiveLeaseOrOriginalProgress navigationRejectsOldWindowCallbacksUntilTheExactTargetWindowIsApplied""",
    "ReaderDomainTests/ImportAdmissionTests.swift": """nonTXTAndNonFileSelectionsAreRejectedBeforeSourceAccessAndNeverEnterShelf""",
    "ReaderDomainTests/ImportDiagnosticsTests.swift": """pickerClosureBeforeSuccessDoesNotInventCancellation pickerClosureAfterSuccessPreservesLatestReadingStage priorAttemptCallbacksAndStagesCannotOverwriteNewAttempt safeFailuresDropPrivateDetailsAndDistinguishRealCancellation observedImportDeliversOrderedStagesWithoutChangingOriginalBytes""",
    "ReaderDomainTests/ImportPickerRouteTests.swift": """selectionBeforeDismissalWaitsAndIsDeliveredExactlyOnce selectionAfterDismissalIsNotLostOrInferredAsCancellation emptyDelegateResultStaysDistinctAndWaitsForDismissal explicitCancellationWorksBeforeOrAfterDismissalWithoutASelection oldCallbacksAndDuplicateDismissalsCannotConsumeTheCurrentRoute""",
    "ReaderDomainTests/LibraryPresentationTests.swift": """importPresentationUsesActualStagesAndIgnoresRetiredAttempts stoppingIsPendingAndAnAuthoritativeCommitNeverBecomesCancelledNotice deferredPreparationStillReportsTheCommittedBookAndPreservedPosition onlyTheActiveAttemptCanRequestStopAndSelectionCancellationIsDistinct""",
    "ReaderDomainTests/LibraryWorkflowTests.swift": """cancelBeforeCommitAndCancelAfterCommitHaveDistinctTruth schemaMigrationPreservesBooksAndAddsValidatedSettings sessionSequenceAndVersionGuardRejectLateOrMismatchedWrites failedFinalSaveStillClosesOldAuthorityWithoutClosingNewSession ambiguityPreviewsUseTheSameLateSegmentAndCancellationLeavesNoBook emptyDamagedAndPrecancelledImportsDoNotCreateShelfRows duplicateRepairsMissingCopyAndKeepsEncodingVersionAndProgress fontSpacingAndWidthChangesKeepTheSameVersionedRawAnchor""",
    "ReaderDomainTests/ProcessingReuseTests.swift": """importedDocumentAndReopenedChaptersAreReusedWithFreshSessionAndProgress warmCacheStillRejectsSameSizeChangesMissingFilesAndWrongMetadata memoryPressureAndCancellationEvictWithoutPublishingUncommittedImports overBudgetFallsBackToOriginalProcessingOnEveryOpen switchingBooksAndDuplicateRepairDoNotReuseWrongContentOrEncoding invalidatedGenerationCannotPublishOrClearNewerContent""",
    "ReaderDomainTests/ReaderSessionLifecycleTests.swift": """supersededOpensAtEachSuspensionCannotRevokeTheLatestSessionOrLease cancellationAfterSourceSessionOrPreferencesClosesOnlyItsOwnResources concurrentClosesJoinOneFinalSaveInsteadOfFinishingEarlyWithNil failedFinalSaveRollsBackAndRevokesWritesWithoutClearingANewerSession closedAndSupersededCallbacksCannotOverwriteNewerProgressOrSettings concurrentMissesShareOneProducerAndCancellingOneConsumerKeepsTheOtherAlive productSummariesReportMeasuredScopesAndLogicalBudgetWithoutPrivateValues""",
    "ReaderDomainTests/ReaderTypographyPresetTests.swift": """presetsKeepTheCurrentThemeAndStayWithinExistingRanges standardRestoresExistingTypographyWithoutForcingThePaperTheme customTypographyDoesNotClaimToMatchAPreset applyingAPresetKeepsTheOriginalPreferencesJSONContract""",
    "ReaderDomainTests/ReadingDirectoryPresentationTests.swift": """actualOpenedReaderLocatesBOMChapterPagesAndEOFWithoutMovingSavedProgress veryLargeDirectoryOnlyUsesLogarithmicProbesAndOneBoundedPage exactBoundariesLastPageAndEmptyDirectoryHaveExplicitSemantics emptyTruncatedWrongVersionAndZeroLengthMetadataAreRejectedWithoutSearchingForHoles cancellationAfterAProbeDoesNotContinueToReadOrProduceAPage queuedCurrentRequestCannotRestartAfterNewPagingOrReplacementOwnerIntent duplicateRequestsAndLateCancelCannotClearTheNewPage onlyExplicitCurrentRevealSurvivesAndPagingDismissalOrStaleDisplayRevokesIt actualQueryRejectsOtherBooksVersionsBOMInteriorsAndClosedReaders""",
    "ReaderDomainTests/ReadingToolsPresentationTests.swift": """centralTapTogglesButAnOldTouchCannotOverrideANewerIntent activeScrollingHidesAndNeitherSettlingNorResumeAutomaticallyRevealsTools panelCloseReturnsCompactAndChapterSelectionReturnsImmersive rapidPanelSwitchRejectsOldCloseSelectionAndQueuedBodyTap suspensionRevokesPanelsAndTouchesWithoutRestoringThemOnResume exitIsSingleFlightAndFailureRestoresAnExplicitExitPath invalidatedReaderRejectsLateExitAndAllOldPresentationActions centralTapCoordinatesUseScrolledBoundsOriginAndRejectEdgesOrInvalidGeometry momentumIsLatchedAtTouchBeginEvenWhenTapUpIsAlreadyIdle repeatedPanelOpenDoesNotAllocateAnotherSessionButExplicitCloseRevokesIt""",
    "ReaderDomainTests/ReadingBookmarkTests.swift": """bookmarkMigrationPreservesV3RowsAndRollsBackFailure bookmarkConcurrentRetriesKeepOriginalIdentityAndTime bookmarkUUIDCollisionAndDatabaseConstraintsNeverReplaceRows bookmarkPagesAreBoundedOrderedAndClampAfterLastPageDeletion bookmarkQueriesAndDeletionAreIsolatedBetweenBooks bookmarkStrictBoundariesCoverFiveEncodingsBOMCRLFAndGraphemes bookmarkEmptyEOFAndCorruptRecordsNeverFallbackToStart bookmarkIncompatibleVersionsRemainVisibleAndExplicitlyDeletable bookmarkPersistenceSurvivesNewStoreDuplicateImportAndCacheRebuild bookmarkMutationsPreserveProgressSettingsAndDerivedPointers bookmarkRevokedRequestAndCancelledTaskCannotWrite bookmarkSupersededAndClosedSessionsLoseAdmission bookmarkPostCommitCancellationReturnsCommittedTruthAndCapsTitle bookmarkSQLFailuresRollbackAndReadFailureIsNotAnEmptyPage""",
    "ProcessingReuseMeasurementTests/ProcessingReuseMeasurementTests.swift": """syntheticImportFirstOpenReopenAndNewServiceColdCache""",
    "YueJingHostTests/ReaderViewportLifecycleTests.swift": """rebuildKeepsDetachedAnchorUntilApplyAndRestoresTheScrolledWindow attachBeforeLateOldDismantlePreservesRestorationAndRejectsOldCallbacks""",
    "YueJingHostTests/ReaderInteractionInterruptionTests.swift": """interruptedDecelerationRecoversOnSameControllerWithoutMovingAnchor interruptionRevokesOldTouchAndAcceptsFreshIntent momentumAtTouchBeginStillStopsBeforeANewIdleTouchCanToggle viewportInterruptionForwardingIsIdempotentAndDetachedControllerIsInert""",
    "YueJingHostTests/ReaderThemeUpdateTests.swift": """sameThemeUpdatesAreIdempotentAndRealChangesStillApply sameThemeDoesNotPreventANewWindowFromApplying""",
    "YueJingHostTests/ReaderSceneAuthorityTests.swift": """nativeSceneAuthorityRejectsStaleOwnersAndDuplicatePhaseWrites""",
    "YueJingHostTests/ReaderBookmarkTests.swift": """bookmarkVisibleCaptureAndMutationsDoNotSaveProgress bookmarkQueuedCancellationAndOldDismissCannotAffectNewPanel bookmarkPreparationPreservesWindowUntilExactApplication bookmarkReflowAndOwnerReplacementRevokeCapturedAndPreparedPositions""",
    "YueJingUITests/ReadingFlowUITests.swift": """testSettingsCloseThenScrollExitAndReopenSameAndOtherBook testReaderThemeDoesNotChangeShelfEnvironment testDirectoryPagingCurrentChapterAndReentryAfterSettings testFullViewportStaysStableAndLongAndShortBookLastLinesFit testRepeatedPanelsAndAuxiliarySheetsReturnOnlyToReading testAccessibilityFontLeavesExitAndPanelControlsReachable testTypographySliderPresetsAndConfirmedRestore testTypographyAndChapterSurviveProcessRelaunch testOtherAppRoundTripRestoresCentralTapAndWindowUpdates testBookmarksPersistIsolateAndJumpAfterRelaunch testNearbyBookmarksKeepIndependentNamesAndExactJumps testBookmarksAccessibilityCloseAndConfirmedDeletion""",
    "YueJingCanvasTests/ReadingCanvasRenderingTests.swift": """dirtyRegionCoversTheSentinelInEveryThemeAndPreservesOutsidePixels reuseRemovesOldInkAndAccessibilityActionsWithoutResettingTheTheme fractionalResizeRerasterizesToTheSameImageAsAFreshCanvas""",
    "TXTCorePerformanceTests/TXTLargeFilePerformanceTests.swift": """automaticDecodeAndChaptersBaseline""",
    "ReaderDomainTests/EPUBLibraryTests.swift": """epubOriginalArchiveAndValidatedResourcesSurviveReopen epubWarmReopenTransfersFolderWithFreshSessionPositionAndPreferences epubOverlappingReadersUseIndependentLeasesAndSessions epubConcurrentWorkspaceTakesConsumeTheSlotOnlyOnce epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime epubWarmPackageMatchIncludesMetadataNotOnlyVersion epubFailedOrCancelledCloseNeverReturnsWorkspace epubFailureAfterWarmTakeDeletesTransferredFolderNotAnUnusedDestination epubCancelledWarmTakeAndImporterDeinitCleanTheirOwnSlot epubDuplicateKeepsProgressAndRepairsMissingArchive epubCancellationBeforeCommitLeavesNoBook epubCancellationAfterCommitReturnsReceipt epubFailedImportCleansOnlyItsWorkspace epubV6MigrationPreservesTXTProgressBookmarksAndPreferences epubCoverThumbnailBoundsAndDamagedFallback epubBooksAndTXTStayIsolated""",
    "ReaderDomainTests/EPUBContentPoolTests.swift": """recentBooksReuseIndependentVersionsWithoutCopying contentLeaseEvictionWaitsForEveryHolderAndRejectsReleasedTokens diskContentSurvivesPoolRecreationAndCancellationPublishesNothing corruptedLeasedVersionIsNotDeletedUntilOldRendererReleasesIt invalidPeerReceiptDoesNotBlockOtherBooks unavailableOptionalCacheFallsBackToTemporaryLeasedContent""",
    "ReaderDomainTests/EPUBProgressTests.swift": """epubPositionsRejectForeignVersionsUnitsAndInvalidUTF16Boundaries epubProgressRequiresReadinessAndIncreasingSequence epubOldNavigationSupersededSessionAndClosedCallbacksCannotWrite epubTypographyEpochRestoresSameTextPositionAndSettings epubViewportOffsetPersistsAndLegacyAnchorsRemainReadable""",
    "ReaderDomainTests/LongBookAcceptanceTests.swift": """a06FixedTenMiB128ChaptersImportNavigateAndReopen""",
    "ReaderDomainTests/EPUBArchiveTests.swift": """epubArchiveExtractsStoredAndDeflatedEntriesWithVerifiedDigests epubArchiveRejectsUnsafePathsAndEncodedTraversals epubArchiveRejectsDuplicateAndUnicodeCollidingCanonicalPaths epubArchiveRejectsSymbolicLinksAndDestinationLinkEscapes epubArchiveRejectsCRCMismatchesAfterStreamingExtraction epubArchiveRejectsTruncatedAndInconsistentHeaders epubArchiveEnforcesCompressedAndStreamedExpansionBudgets epubArchiveEnforcesMaximumEntryCountBudget epubArchiveRejectsEncryptedAndUnsupportedCompressionEntries epubArchiveRespectsTaskCancellationAndCleansDestination""",
    "ReaderDomainTests/EPUBPackageTests.swift": """epubPackageParsesEPUB3AndEPUB2ContainersInExactSpineOrder epubPackageResolvesNavAndNCXHierarchyWithValidatedFragments epubPackageRejectsXXEDTDAndEntityDeclarationsAcrossUTF8AndUTF16 epubPackageRejectsMissingMetadataEmptyBodyAndDuplicateManifestItems epubPackageRejectsBrokenSpineAndBodyResourceReferences epubPackageRejectsEncryptedFixedLayoutAndActiveContent epubPackageSelectsValidCoversAndFallsBackOnOptionalCoverProblems epubPackageFailsFatallyOnCorruptBodyImageOrArchiveIntegrityError""" ,
    "YueJingHostTests/EPUBReaderHostTests.swift": """epubOpeningObservationRejectsStaleFramesAndLabelsColdAdmission epubOpeningRouteStartsOnceAndObservesMountedPresentation epubWebKitLoadsValidatedLocalResourcesAndRestoresTextNodeUTF16Position epubSecurityRejectsScriptsFormsExternalResourcesAndKeepsIsolatedLocatorWorking epubTypographyReflowRestoresAnchorAndGatesStaleNavigationCallbacks epubShelfCoverThumbnailDisplaysAndMissingOrDamagedCoversFallbackCleanly epubCompatibilityWebKitLoadsStaticImagePageAndRestoresAnchor epubRecentBooksReusePagesAcrossSwitchesAndEvictOnlyIdleLRU epubFailedRestorationRejectsLateReadyAndPendingContinuation epubBoundaryViewportRestoresInFreshControllerAfterCloseOrSuspend epubLayoutModeDefaultsToOriginalFallsBackOnUnknownAndPersistsReaderPreference epubWebKitAppliesAuthorCSSPerChapterSwitchesLayoutModesAndReopensColdAndWarm epubResourceHandlerEnforcesFontCapabilityMediaTypeAndHashVerification""",
    "YueJingEPUBUITests/EPUBFlowUITests.swift": """testEPUBShelfCoverAndDirectoryCrossChapterNavigation testEPUBProgressSurvivesExitAndProcessRelaunch testEPUBTypographyNoCoverFallbackAndTXTIsolation""" ,
    "ReaderDomainTests/EPUBCompatibilityTests.swift": """epubCompatibilityStandardDoctypesPreserveAcceptedTextBytesAndNodes epubCompatibilityRejectsEntitiesUnknownDuplicateAndMisplacedDoctypes epubCompatibilityStaticSVGBecomesLocalJPEGAndPreservesIDs epubCompatibilityRejectsComplexActiveAndEscapingSVG epubCompatibilityImageOnlyPagesHaveStableAnchorButBlankPagesFail epubCompatibilityWebPRequiresRealBoundedSingleFrameDecode epubCompatibilityEPUB2DoctypeImageWebPImportProgressSurvivesReopen epubCompatibilityWebPResourcesStillEnforceSizeAndDigestIntegrity""",
    "ReaderDomainTests/EPUBReadyTests.swift": """readyNodePackKeepsExactNodesWithSmallManifest readyImportColdReaderDoesNotDependOnParkedLease legacyMigrationPreservesProgressPreferencesAndOriginal readyUnvisitedNodeDamageIsDetectedBeforeOpenAndRepairedWithLeaseIsolation readyPublicationRollbackAndReconciliationProtectLiveVersions readyManifestMutationCannotBeBlessedByRepair boundedParallelVerificationMatchesSerialIntegrityAndCancellation resourceVerificationTimingsAreBoundedAndIdentityFree measuredResourceVerificationMatchesSerialFailuresAndCancellation readyResourceTimingsDistinguishDiskRegistrationFromVerifiedReuse""",
    "ReaderDomainTests/EPUBAuthorStylesTests.swift": """authorStylesSanitizesExternalInlineAndClassCSSWithScopedSelectors authorStylesEmbedsManifestFontsAndIsolatesChapters authorStylesDropsUnsafeLayoutAndGuardsReaderAndLocatorNodes authorStylesRejectsEscapedMaliciousCSSExternalURLsAndUnknownResources authorStylesRejectsCorruptOversizedAndInvalidSFNTFontsAndDRM""",
    "ReaderDomainTests/EPUBAuthorStyleMigrationTests.swift": """legacyPackageWithoutAuthorStyleRevisionDecodesCompatibly authorStyleMigrationRebuildsReadyAndNonReadyLegacyPackagesPreservingTextProgressAndSource authorStyleMigrationValidationRejectsCoordinateMetadataResourceAndRevisionMismatches failedAuthorStyleMigrationPreservesPreviousStorageProgressAndArchive""",
    "YueJingHostTests/EPUBContentsNavigationTests.swift": """largeDirectoryResolvesFirstMiddleAndLast samePathPrefersFragmentThenFallsBackToFirstPath filteringKeepsOriginalIndicesOrdinalsAndItems emptyAndUnmatchedDirectoriesHaveNoInventedTarget lazyMountCorrectionIsBoundedAndOnlyForTheTarget cancellationAndNewRequestsInvalidateLateWork""",
    "YueJingHostTests/EPUBFontLoadingHostTests.swift": """epubWebKitDecodesSyntheticFontServesResourceAndMeasuresGlyphMetrics epubWebKitGatesReadinessOnFontDecodingAndRebindsCapabilityAcrossEpochs""",
}
COUNTS = {"TXTCoreTests": 25, "ReaderDomainTests": 180, "TXTBlockDecoderTests": 6,
          "ProcessingReuseMeasurementTests": 1, "YueJingHostTests": 34,
          "YueJingUITests": 12, "YueJingCanvasTests": 3, "YueJingEPUBUITests": 3}
SWIFT_GROUPS = tuple(list(COUNTS)[:4]) + ("YueJingCanvasTests",)
TOTAL = 264  # Declaration identities; the Bool parameter adds one execution (265).
PARAMETERIZED = {"epubDamagedClosedWorkspaceFallsBackWithoutTrustingMtime": {
    "signature": "(symlink:)", "argument": "symlink", "values": ["false", "true"]}}
EXECUTION_COUNTS = {**COUNTS, "ReaderDomainTests": 181}
EXECUTION_TOTAL = 265
EXCLUDED = {"TXTCorePerformanceTests": "Independent large-file performance baseline; not this acceptance batch."}


def group_for(path):
    if path == "TXTCoreTests/TXTBlockDecoderTests.swift":
        return "TXTBlockDecoderTests"
    return path.split("/")[0]


def expected_names(group):
    return [name for path, names in sorted(FILES.items()) if group_for(path) == group for name in names.split()]


def source_names(path, text):
    # Bounded to this repository's declaration style, including @Test(.timeLimit(...)).
    # A changed/unsupported annotation fails the full @Test-count cross-check below.
    if path.startswith(("YueJingUITests/", "YueJingEPUBUITests/")):
        return re.findall(r"\bfunc\s+(test\w+)\s*\(", text)
    names = re.findall(r"@Test(?:\([^\r\n]*\))?\s+func\s+(\w+)\s*\(", text)
    if len(names) != len(re.findall(r"@Test\b", text)):
        raise ValueError("Unsupported test declaration syntax: " + path)
    return names


def validate_source(root=ROOT):
    actual = {}
    for path in sorted((root / "Tests").rglob("*.swift")):
        relative = path.relative_to(root / "Tests").as_posix()
        names = source_names(relative, path.read_text(encoding="utf-8"))
        if names:
            actual[relative] = names
    expected = {p: n.split() for p, n in FILES.items()}
    if actual != dict(sorted(expected.items())):
        raise ValueError("Source declarations differ from reviewed per-file/per-case inventory")
    for group, count in {**COUNTS, "TXTCorePerformanceTests": 1}.items():
        names = expected_names(group)
        if len(names) != len(set(names)) or len(names) != count:
            raise ValueError("Frozen case inventory/count mismatch: " + group)
    names = [n for g in COUNTS for n in expected_names(g)]
    if len(names) != len(set(names)) or len(names) != TOTAL:
        raise ValueError("Task3 selected union is not unique/complete")
    parameter_source = (root / "Tests/ReaderDomainTests/EPUBLibraryTests.swift").read_text(encoding="utf-8")
    name = next(iter(PARAMETERIZED))
    if not re.search(r"@Test\(arguments: \[false, true\]\)\s+func " + name + r"\(symlink: Bool\)", parameter_source):
        raise ValueError("Reviewed Bool argument matrix changed")
    return {"kind": "SOURCE_INVENTORY_NOT_NATIVE", "groups": COUNTS, "selected": TOTAL,
            "execution_groups": EXECUTION_COUNTS, "selected_executions": EXECUTION_TOTAL,
            "parameterized": PARAMETERIZED, "excluded": EXCLUDED,
            "all_declared": TOTAL + 1, "native_executions": 0,
            "cases": {g: expected_names(g) for g in (*COUNTS, *EXCLUDED)}}


def selection(group):
    if group not in COUNTS:
        raise ValueError("Not an authorized Task3 group: " + group)
    if group == "TXTBlockDecoderTests":
        return ["-only-testing:TXTCoreTests/TXTBlockDecoderTests"]
    if group == "ProcessingReuseMeasurementTests":
        return ["-only-testing:ReaderDomainTests/ProcessingReuseMeasurementTests"]
    result = ["-only-testing:" + group]
    if group == "TXTCoreTests":
        result.append("-skip-testing:TXTCoreTests/TXTBlockDecoderTests")
    if group == "ReaderDomainTests":
        result.append("-skip-testing:ReaderDomainTests/ProcessingReuseMeasurementTests")
    return result


def parameter_events(text, expected):
    """Adapt only reviewed signatures in memory; retain every original argument row.

    Swift Testing reports a parent finish, not a separate console finish per argument.
    A passing parent plus exactly both argument starts is necessary; the release gate
    additionally requires both successful argument leaves in the real xcresult.
    """
    adapted, records = text, {}
    for name, spec in PARAMETERIZED.items():
        if name not in expected:
            continue
        signature = name + spec["signature"]
        starts = list(re.finditer(r"\bTest " + re.escape(signature) + r" started\.", text))
        ends = list(re.finditer(r"\bTest " + re.escape(signature) + r" passed after ([0-9.]+) seconds?", text))
        if len(starts) != 1 or len(ends) != 1 or not starts[0].start() < ends[0].start() or float(ends[0][1]) > 180:
            raise ValueError("Invalid parameterized parent events")
        rows = []
        for number, line in enumerate(text.splitlines(), 1):
            if "Passing " not in line:
                continue
            match = re.fullmatch(r"\u200b?(?:◇ )?Passing 1 argument " + spec["argument"] +
                                 r" → (false|true)(?: \(Bool\))? to " + re.escape(signature) + r"\.?", line)
            if not match:
                raise ValueError("Unrecognized/foreign argument event")
            rows.append(dict(line=number, text=line, value=match[1]))
        start_line = text[:starts[0].start()].count("\n") + 1
        end_line = text[:ends[0].start()].count("\n") + 1
        if sorted(row["value"] for row in rows) != sorted(spec["values"]) or not all(start_line < row["line"] < end_line for row in rows):
            raise ValueError("Missing/duplicate/out-of-order Bool argument execution")
        records[name] = rows
        adapted = adapted.replace(signature, name + "()")
    if not records and re.search(r"(?:^|\n)\u200b?(?:◇ )?Passing ", text):
        raise ValueError("Unexpected parameterized execution")
    return adapted, records


def parse_swift_log(group, log, native_exit):
    expected = expected_names(group)
    log, arguments = parameter_events(log, expected)
    passed = re.findall(r"\bTest (\w+)\(\) passed after\b", log)
    summaries = re.findall(r"Test run with (\d+) tests?\b[^\r\n]*?\b(passed|failed)\b", log)
    bad = re.search(r"^.*\b(?:Test|Suite)[^\r\n]*\b(?:skipped|failed)\b", log, re.MULTILINE)
    if group not in SWIFT_GROUPS or native_exit != 0 or bad or "** TEST SUCCEEDED **" not in log:
        raise ValueError("Native failure/skip/exit or missing success: " + group)
    if summaries != [(str(COUNTS[group]), "passed")] or sorted(passed) != sorted(expected):
        raise ValueError("Missing/duplicate/unexpected case execution: " + group)
    if arguments:
        import audit_native_case_events as audit
        parsed = audit.parse_events(log.encode(), expected)
        if not parsed["parser_complete"] or parsed["totals"]["passed"] != len(expected):
            raise ValueError("Incomplete parameterized native event stream")
    return {"declared": expected, "passed": passed, "native_summaries": summaries,
            "parameter_events": arguments, "skipped": [], "native_exit": native_exit}


def self_check():
    checked = []
    for group in SWIFT_GROUPS:
        lines = []
        for name in expected_names(group):
            spec = PARAMETERIZED.get(name)
            signature = name + (spec["signature"] if spec else "()")
            row = f"◇ Test {signature} started.\n"
            if spec:
                row += "".join(f"◇ Passing 1 argument symlink → {value} to {signature}\n" for value in spec["values"])
            lines.append(row + f"✔ Test {signature} passed after 0.1 seconds.")
        tail = f"Test run with {COUNTS[group]} tests passed after 1 seconds.\n** TEST SUCCEEDED **"
        good = "\n".join(lines + [tail])
        parse_swift_log(group, good, 0)
        checked.append(group + ":accept")
        for label, log, code in (("missing", "\n".join(lines[1:] + [tail]), 0),
                                 ("duplicate", good + "\n" + lines[0], 0),
                                 ("unexpected", good.replace(lines[0], "Test alien() passed after 0.1 seconds."), 0),
                                 ("skipped", good + "\nTest example skipped", 0),
                                 ("failed", good + "\nTest example failed", 0),
                                 ("exit", good, 65), ("success_marker", good.replace("** TEST SUCCEEDED **", ""), 0)):
            try:
                parse_swift_log(group, log, code)
            except ValueError:
                checked.append(group + ":reject_" + label)
            else:
                raise ValueError("Synthetic parser accepted " + group + ":" + label)
    return {"kind": "SYNTHETIC_PARSER_NOT_NATIVE", "passed": len(checked), "native_executions": 0, "cases": checked}


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["--selection"]:
        raise SystemExit("Specify a group")
    if len(sys.argv) == 3 and sys.argv[1] == "--selection":
        validate_source()
        print(" ".join(selection(sys.argv[2])))
    else:
        print(json.dumps(validate_source(), indent=2))
        if "--self-check" in sys.argv:
            print(json.dumps(self_check(), indent=2))
