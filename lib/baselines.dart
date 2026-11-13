/// The machine baselines without the comparator: the key, the store, the
/// builder and the report, in plain Dart, for the `prepare` and `report`
/// commands, which run outside a Flutter test.
library;

export 'src/builder.dart'
    show BaselineBuilder, CheckoutUnavailable, ProcessRunner, childEnvironmentVariable;
export 'src/git.dart' show GitRepo;
export 'src/machine_key.dart' show MachineKey;
export 'src/report.dart' show GoldenOutcome, GoldenReport, ReportEntry;
export 'src/session.dart'
    show
        BranchChangedBaseline,
        CommittedBaseline,
        GoldenBaseline,
        MachineBaseline,
        MachineGoldens,
        baseEnvironmentVariable;
export 'src/store.dart'
    show BaselineStore, BuildFailure, Built, cacheEnvironmentVariable, defaultCacheRoot;
