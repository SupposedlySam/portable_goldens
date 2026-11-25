/// The machine baselines without the comparator: the key, the store, the
/// builder, the report and the verifier, in plain Dart, for the `prepare`,
/// `report` and `verify` commands, which run outside a Flutter test.
library;

export 'src/build/baseline_builder.dart'
    show BaselineBuilder, childEnvironmentVariable, defaultGoldenTestMarker;
export 'src/build/checkout_unavailable.dart' show CheckoutUnavailable;
export 'src/build/setup_steps.dart'
    show SetupConfigError, SetupSteps, configKey;
export 'src/git/committed_file.dart'
    show CommittedBytes, CommittedFile, LfsPointer, UnknownFile, UnreadFile;
export 'src/git/git_repo.dart' show GitRepo;
export 'src/git/package_location.dart' show PackageLocation;
export 'src/machine/flutter_sdk.dart' show FlutterSdk;
export 'src/machine/machine_key.dart' show MachineKey;
export 'src/process/process_runner.dart' show ProcessRunner;
export 'src/report/golden_report.dart' show GoldenReport;
export 'src/report/report_entry.dart' show GoldenOutcome, ReportEntry;
export 'src/report/test_run.dart' show currentRun;
export 'src/report/work_summary.dart' show ChangedGolden, WorkSummary;
export 'src/session/branch_change.dart' show BranchChange;
export 'src/session/fallback_reason.dart'
    show CheckoutFailed, FallbackReason, GoldenFallback, SessionFallback;
export 'src/session/golden_baseline.dart'
    show
        CommittedBaseline,
        GoldenBaseline,
        MachineBaseline,
        WorkingTreeBaseline;
export 'src/session/machine_goldens.dart'
    show MachineGoldens, baseEnvironmentVariable;
export 'src/store/baseline_store.dart' show BaselineStore;
export 'src/store/build_failure.dart' show BuildFailure, Built;
export 'src/store/cache_root.dart'
    show cacheEnvironmentVariable, defaultCacheRoot;
export 'src/store/commit_baselines.dart' show CommitBaselines;
export 'src/verify/flutter_pixel_comparer.dart'
    show FlutterPixelComparer, verifyManifestVariable;
export 'src/verify/golden_check.dart'
    show GoldenCheck, Mismatch, Unbuilt, Uncommitted, Unverifiable, Verified;
export 'src/verify/golden_verifier.dart' show GoldenVerifier;
export 'src/verify/pixel_comparer.dart'
    show ImagePair, PixelCompareFailure, PixelComparer, PixelVerdict;
