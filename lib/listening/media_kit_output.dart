import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import 'controller.dart';

/// libmpv-backed output for desktops: just_audio/audio_session have no Linux
/// implementations, while media_kit ships one runtime for every desktop.
/// Pause/seek still keep the exact audio position — no TTS speak() simulation.
class MediaKitListeningOutput implements ListeningAudioOutput {
  final ListeningController controller;
  final Player _player = Player(
    configuration: const PlayerConfiguration(
      // Speech clips load whole-file from disk; a small buffer starts faster.
      bufferSize: 4 * 1024 * 1024,
    ),
  );
  final _completed = StreamController<void>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  MediaKitListeningOutput(this.controller) {
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed) _completed.add(null);
      }),
    );
    _subscriptions.add(
      _player.stream.error.listen((error) {
        _completed.addError(error);
      }),
    );
  }

  @override
  Stream<Duration> get positions => _player.stream.position;

  @override
  Stream<void> get completions => _completed.stream;

  @override
  Future<Duration?> load(File file, Duration position) async {
    await _player.open(Media(file.path), play: false);
    if (position > Duration.zero) {
      await _player.seek(position);
    }
    return _player.state.duration;
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> suspend() => _player.pause();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _completed.close();
  }
}
