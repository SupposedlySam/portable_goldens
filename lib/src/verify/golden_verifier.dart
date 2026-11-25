import 'dart:io';

import 'package:portable_goldens/src/git/committed_file.dart';
import 'package:portable_goldens/src/git/sha.dart';
import 'package:portable_goldens/src/session/golden_baseline.dart';
import 'package:portable_goldens/src/session/machine_goldens.dart';
import 'package:portable_goldens/src/store/build_failure.dart';
import 'package:portable_goldens/src/verify/golden_check.dart';
import 'package:portable_goldens/src/verify/pixel_comparer.dart';

/// Checks that each committed png is what its own commit draws on this
/// machine.
///
/// A png committed ahead of its code, or with part of it (`git add -p`, a
/// rebase that split a commit), is a picture its commit cannot draw. Every
/// machine then compares that golden with a render that differs from the
/// png, and the golden fails where plain Flutter would pass; or a stale png
/// passes forever. Nothing else notices, so this asks the question
/// directly: render the commit here, compare it with the png it committed.
///
/// That is only meaningful on the machine that rendered the png. Anywhere
/// else, every png differs from the render by the machine as well as the
/// commit.
final class GoldenVerifier {
  /// Checks [goldens]' pngs, comparing pixels with [pixels] and keeping the
  /// images of each mismatch below [outputDir].
  new({required this.goldens, required this.pixels, required this.outputDir});

  /// The package's machine baselines.
  final MachineGoldens goldens;

  /// The pixel compare, for a png whose bytes differ from its render.
  final PixelComparer pixels;

  /// Where the images of a mismatch go: one folder per golden, holding the
  /// committed png, the render and the diffs.
  final String outputDir;

  /// The checks of the goldens matching [pathspec]: every tracked one when
  /// [all], else the ones this branch changed. In the order git lists them.
  ///
  /// A png the working tree changed since HEAD is checked as HEAD has it.
  Future<List<GoldenCheck>> verify(String pathspec, {required bool all}) async {
    final tracked = await goldens.goldens(pathspec);
    final candidates = all ? tracked : await goldens.changedByBranch(pathspec);
    final checks = <GoldenCheck?>[];
    final pending = <_Pending>[];
    for (final golden in candidates) {
      if (!tracked.contains(golden)) {
        checks.add(Uncommitted(golden));
        continue;
      }
      switch (await _check(golden)) {
        case _Checked(:final check):
          checks.add(check);
        case final _Pending differs:
          pending.add(differs..slot = checks.length);
          checks.add(null);
      }
    }
    for (final (index, check) in (await _comparePixels(pending)).indexed) {
      checks[pending[index].slot] = check;
    }
    return [for (final check in checks) ?check];
  }

  Future<_Step> _check(String golden) async {
    final GoldenBaseline baseline;
    try {
      baseline = await goldens.baselineAtHead(golden);
    } on BuildFailure catch (failure) {
      return _Checked(Unbuilt(golden, failure));
    }
    switch (baseline) {
      case CommittedBaseline(:final reason):
        return _Checked(Unverifiable(golden, reason.phrase));
      case WorkingTreeBaseline():
        // baselineAtHead never answers this; said rather than assumed.
        return _Checked(
          Unverifiable(golden, 'its baseline is the working tree'),
        );
      case MachineBaseline(:final file, :final commit):
        final List<int> committed;
        switch (await goldens.committedImage(commit, golden)) {
          case CommittedBytes(:final bytes):
            committed = bytes;
          case final UnknownFile unknown:
            return _Checked(
              Unverifiable(
                golden,
                "${shortSha(commit)}'s png is unknown here: ${unknown.why}",
              ),
            );
          case null:
            return _Checked(
              Unverifiable(golden, '${shortSha(commit)} has no such png'),
            );
        }
        final rendered = await file.readAsBytes();
        if (_sameBytes(committed, rendered)) {
          return _Checked(Verified(golden, commit));
        }
        return _Pending(golden, commit, committed, file);
    }
  }

  // Equal bytes are equal pixels, and the common case; different bytes may
  // still be equal pixels (another encoder), so those go to [pixels].
  Future<List<GoldenCheck>> _comparePixels(List<_Pending> pending) async {
    if (pending.isEmpty) return const [];
    final pairs = [for (final p in pending) _keep(p)];
    final List<PixelVerdict> verdicts;
    try {
      verdicts = await pixels.compare(pairs);
    } on PixelCompareFailure catch (failure) {
      return [
        for (final p in pending)
          Unverifiable(p.golden, 'the pixel compare failed: $failure'),
      ];
    }
    return [
      for (final (index, p) in pending.indexed)
        if (verdicts[index].isSame)
          Verified(p.golden, p.commit)
        else
          Mismatch(
            p.golden,
            p.commit,
            committed: pairs[index].committed,
            rendered: pairs[index].rendered,
            diffs: verdicts[index].diffs,
            difference: verdicts[index].difference ?? 'the images differ',
          ),
    ];
  }

  // Copies both images into the golden's own folder, so a mismatch's three
  // or four images sit side by side, and stale diffs of an earlier run are
  // gone.
  ImagePair _keep(_Pending p) {
    final dir = Directory('$outputDir/${p.golden}');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final committed = File('${dir.path}/committed.png')
      ..writeAsBytesSync(p.committed);
    final rendered = p.render.copySync('${dir.path}/rendered.png');
    return ImagePair(
      committed: committed.path,
      rendered: rendered.path,
      diffDir: dir.path,
    );
  }
}

// One golden's step: checked already, or waiting for the pixel compare.
sealed class _Step;

final class _Checked extends _Step {
  new(this.check);

  final GoldenCheck check;
}

// A png whose bytes differ from its render, so its pixels are compared.
final class _Pending extends _Step {
  new(this.golden, this.commit, this.committed, this.render);

  final String golden;
  final String commit;
  final List<int> committed;
  final File render;

  // Where its check goes in the result.
  int slot = -1;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
