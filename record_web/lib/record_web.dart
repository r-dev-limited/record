import 'dart:async';
import 'dart:html' as html;
import 'dart:web_audio' as web_audio;
import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:record_web/mime_types.dart';
import 'dart:math';

class RecordPluginWeb extends RecordPlatform {
  static void registerWith(Registrar registrar) {
    RecordPlatform.instance = RecordPluginWeb();
  }

  // Media recorder object
  html.MediaRecorder? _mediaRecorder;
  web_audio.AudioContext? _audioContext;
  web_audio.AnalyserNode? _analyserNode;
  double maxAmplitude = -160;

  Float32List dataArray = Float32List(0);
  // Media stream get from getUserMedia
  html.MediaStream? _mediaStream;
  // Audio data
  List<html.Blob> _chunks = [];
  // Completer to get data & stop events before `stop()` method ends
  Completer<String>? _onStopCompleter;
  StreamController<RecordState>? _stateStreamCtrl;

  @override
  Future<void> dispose() async {
    _mediaRecorder?.stop();
    _stateStreamCtrl?.close();
    _resetMediaRecorder();
  }

  double logBase(num x, num base) => log(x) / log(base);

  @override
  Future<bool> hasPermission() async {
    final mediaDevices = html.window.navigator.mediaDevices;
    if (mediaDevices == null) return false;

    try {
      await mediaDevices.getUserMedia({'audio': true});
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isPaused() async {
    return _mediaRecorder?.state == 'paused';
  }

  @override
  Future<bool> isRecording() async {
    return _mediaRecorder?.state == 'recording';
  }

  @override
  Future<void> pause() async {
    _mediaRecorder?.pause();

    _updateState(RecordState.pause);
  }

  @override
  Future<void> resume() async {
    _mediaRecorder?.resume();

    _updateState(RecordState.record);
  }

  @override
  Future<void> start({
    String? path,
    AudioEncoder encoder = AudioEncoder.aacLc,
    int bitRate = 128000,
    int samplingRate = 44100,
    int numChannels = 2,
    InputDevice? device,
  }) async {
    _mediaRecorder?.stop();
    _resetMediaRecorder();

    final constraints = {
      'audio': true,
      'audioBitsPerSecond': bitRate,
      'bitsPerSecond': bitRate,
      'sampleRate': samplingRate,
      'channelCount': numChannels,
      if (device != null) 'deviceId': {'exact': device.id}
    };

    // Try to assign dedicated mime type.
    // If contrainst isn't set, browser will record with its default codec.
    final mimeType = _getSupportedMimeType(encoder);
    if (mimeType != null) {
      constraints['mimeType'] = mimeType;
    }

    try {
      _mediaStream = await html.window.navigator.mediaDevices?.getUserMedia(
        constraints,
      );
      if (_mediaStream != null) {
        _onStart(_mediaStream!);
      } else {
        _log('Audio recording not supported.');
      }
    } catch (error) {
      _onError(error);
    }
  }

  @override
  Future<String?> stop() async {
    _onStopCompleter = Completer();

    _mediaRecorder?.stop();

    _updateState(RecordState.stop);

    return _onStopCompleter?.future;
  }

  @override
  Future<List<InputDevice>> listInputDevices() async {
    final devices = <InputDevice>[];

    final mediaDevices = html.window.navigator.mediaDevices;
    try {
      if (mediaDevices == null) {
        _onError('enumerateDevices() not supported.');
        return devices;
      }

      final deviceInfos = await mediaDevices.enumerateDevices();
      for (var info in deviceInfos) {
        if (info is html.MediaDeviceInfo &&
            info.kind == 'audioinput' &&
            info.deviceId != null &&
            info.label != null) {
          devices.add(InputDevice(id: info.deviceId!, label: info.label!));
        }
      }
    } catch (error) {
      _onError(error);
    }

    return devices;
  }

  void _onStart(html.MediaStream stream) {
    _mediaRecorder = html.MediaRecorder(stream);
    _mediaRecorder?.addEventListener('dataavailable', _onDataAvailable);
    _mediaRecorder?.addEventListener('stop', _onStop);
    _mediaRecorder?.start();

    _audioContext = web_audio.AudioContext();
    var source = _audioContext!.createMediaStreamSource(stream);
    _analyserNode = _audioContext!.createAnalyser();
    _analyserNode!.fftSize = 2048;
    var bufferLength = _analyserNode!.frequencyBinCount;
    dataArray = Float32List(bufferLength ?? 0);
    source.connectNode(_analyserNode! as web_audio.AudioNode);

    _updateState(RecordState.record);
  }

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) {
    final type = _getSupportedMimeType(encoder);

    return Future.value(type != null ? true : false);
  }

  @override
  Future<Amplitude> getAmplitude() async {
    _analyserNode?.getFloatTimeDomainData(dataArray);
    // Compute average power over the interval.
    double sumOfSquares = 0.0;
    for (var i = 0; i < dataArray.length; i++) {
      sumOfSquares += pow(dataArray[i], 2) as double;
    }
    var avgPowerDecibels = 10 * logBase(sumOfSquares / dataArray.length, 10);

    // Compute peak instantaneous power over the interval.
    double peakInstantaneousPower = 0;
    for (var i = 0; i < dataArray.length; i++) {
      var power = pow(dataArray[i], 2) as double;
      peakInstantaneousPower = max(power, peakInstantaneousPower);
    }
    var peakInstantaneousPowerDecibels =
        10 * logBase(peakInstantaneousPower, 10);

    print(avgPowerDecibels);
    print(peakInstantaneousPowerDecibels);

    if (peakInstantaneousPowerDecibels > maxAmplitude) {
      maxAmplitude = peakInstantaneousPowerDecibels;
    }

    return Amplitude(
        current: peakInstantaneousPowerDecibels.toDouble(), max: maxAmplitude);
  }

  @override
  @override
  Stream<RecordState> onStateChanged() {
    _stateStreamCtrl ??= StreamController(
      onCancel: () {
        _stateStreamCtrl?.close();
        _stateStreamCtrl = null;
      },
    );

    return _stateStreamCtrl!.stream;
  }

  String? _getSupportedMimeType(AudioEncoder encoder) {
    final types = mimeTypes[encoder];
    if (types == null) return null;

    for (var type in types) {
      if (html.MediaRecorder.isTypeSupported(type)) {
        return type;
      }
    }

    return null;
  }

  void _onError(dynamic error) {
    _resetMediaRecorder();
    _log(error);
  }

  void _onDataAvailable(html.Event event) {
    if (event is html.BlobEvent && event.data != null) {
      _chunks.add(event.data!);
    }
  }

  void _onStop(html.Event event) {
    String? audioUrl;

    if (_chunks.isNotEmpty) {
      final blob = html.Blob(_chunks);
      audioUrl = html.Url.createObjectUrl(blob);
    }

    _resetMediaRecorder();

    _onStopCompleter?.complete(audioUrl);
  }

  void _resetMediaRecorder() {
    _mediaRecorder?.removeEventListener('dataavailable', _onDataAvailable);
    _mediaRecorder?.removeEventListener('onstop', _onStop);
    _mediaRecorder = null;

    final tracks = _mediaStream?.getTracks();

    if (tracks != null) {
      for (var track in tracks) {
        track.stop();
      }

      _mediaStream = null;
    }

    _chunks = [];
  }

  void _log(String msg) {
    if (kDebugMode) print(msg);
  }

  void _updateState(RecordState state) {
    if (_stateStreamCtrl?.hasListener ?? false) {
      _stateStreamCtrl?.add(state);
    }
  }
}
