import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/person_data.dart';
import '../services/storage_service.dart';

class RealtimeFaceRecognition extends StatefulWidget {
  const RealtimeFaceRecognition({super.key});

  @override
  RealtimeFaceRecognitionState createState() => RealtimeFaceRecognitionState();
}

class RealtimeFaceRecognitionState extends State<RealtimeFaceRecognition> with WidgetsBindingObserver {
  static const double _recognitionThreshold = 0.18;
  static const Duration _recognitionCooldown = Duration(seconds: 5);
  static const Duration _fallbackCaptureInterval = Duration(milliseconds: 300);
  static const String _modelPath = 'assets/model/mobilefacenet.tflite';
  static const int _inputSize = 112;

  CameraController? _cameraController;
  Interpreter? _interpreter;
  Timer? _fallbackTimer;

  bool _isProcessing = false;
  bool _isInitialized = false;
  String _statusMessage = 'Initializing...';
  String _predictedName = '';

  img.Image? _lastFrameImage;
  List<double>? _lastEmbedding;
  DateTime? _lastRecognitionTime;
  String? _lastRecognizedPerson;

  final Map<String, PersonData> _knownPersons = {};

  final Uri _sheetUrl = Uri.parse(
    'https://script.google.com/macros/s/AKfycbxdOwEuwAgXdGfnRL27sULQ7cIldIzPbt9wIxYSYwULGdGz1N0QQEiU-l1rjxt2fn3p/exec',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  Future<void> _initialize() async {
    try {
      await _loadModel();
      await _initCamera();
      await _loadSavedData();

      setState(() {
        _isInitialized = true;
        _statusMessage = 'Ready';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Initialization error: $e';
      });
      if (kDebugMode) print('Initialization error: $e');
    }
  }

  Future<void> _loadModel() async {
    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
        _modelPath,
        options: options,
      );
      if (kDebugMode) print('Model loaded successfully');
    } catch (e) {
      if (kDebugMode) print('Model loading error: $e');
      rethrow;
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await CameraPlatform.instance.availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }

      final camera = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      await _startCamera();

    } catch (e) {
      if (kDebugMode) print('Camera initialization error: $e');
      rethrow;
    }
  }

  Future<void> _startCamera() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    _fallbackTimer?.cancel();

    if (!Platform.isWindows && _cameraController!.value.isStreamingImages == false) {
      try {
        await _cameraController!.startImageStream(_onFrameAvailable);
      } catch (e) {
        if (kDebugMode) {
          print('Failed to start image stream: $e, using fallback method');
        }
        _useFallbackCapture();
      }
    } else if (Platform.isWindows) {
      _useFallbackCapture();
    }
  }

  void _useFallbackCapture() {
    _fallbackTimer = Timer.periodic(_fallbackCaptureInterval, (_) async {
      try {
        if (_isProcessing || _cameraController == null ||
            !_cameraController!.value.isInitialized) {
          return;
        }

        final XFile file = await _cameraController!.takePicture();
        final bytes = await File(file.path).readAsBytes();
        final frame = img.decodeImage(bytes);
        if (frame != null) {
          _processFrame(frame);
        }
      } catch (e) {
        if (kDebugMode) print('Fallback capture error: $e');
      }
    });
  }

  Future<void> _stopCamera() async {
    _fallbackTimer?.cancel();

    if (_cameraController != null &&
        _cameraController!.value.isInitialized &&
        _cameraController!.value.isStreamingImages) {
      await _cameraController!.stopImageStream();
    }
  }

  Future<void> _loadSavedData() async {
    try {
      final persons = await StorageService().loadKnownPersons();
      setState(() {
        _knownPersons.clear();
        _knownPersons.addAll(persons);
      });
      if (kDebugMode) {
        print('Loaded ${persons.length} known persons');
      }
    } catch (e) {
      if (kDebugMode) print('Error loading saved data: $e');
    }
  }

  void _onFrameAvailable(CameraImage image) {
    if (_isProcessing || _interpreter == null) return;
    try {
      final frame = _convertCameraImageToImage(image);
      _processFrame(frame);
    } catch (e) {
      if (kDebugMode) print('Frame processing error: $e');
    }
  }

  Future<void> _processFrame(img.Image frame) async {
    _isProcessing = true;
    try {
      _lastFrameImage = frame;

      final resized = img.copyResize(
        frame,
        width: _inputSize,
        height: _inputSize,
        interpolation: img.Interpolation.linear,
      );

      final input = List.generate(
        1,
            (_) => List.generate(
          _inputSize,
              (y) => List.generate(_inputSize, (x) {
            final p = resized.getPixel(x, y);
            return [
              (p.r - 127.5) / 127.5,
              (p.g - 127.5) / 127.5,
              (p.b - 127.5) / 127.5,
            ];
          }),
        ),
      );

      final outputTensor = _interpreter!.getOutputTensor(0);
      final shape = outputTensor.shape;
      final embeddingLength = shape[1];
      final out = List.filled(embeddingLength, 0.0).reshape([1, embeddingLength]);
      _interpreter!.run(input, out);

      _lastEmbedding = List<double>.from(out[0] as List);

      final matchResult = _findBestMatch(_lastEmbedding!);
      final now = DateTime.now();

      setState(() {
        _predictedName = matchResult.name == 'Unknown'
            ? 'Unknown'
            : '${matchResult.name} (${matchResult.distance.toStringAsFixed(2)})';
      });

      if (matchResult.name != 'Unknown' && matchResult.distance <= _recognitionThreshold) {
        final canSendRecognition = _lastRecognizedPerson != matchResult.name ||
            _lastRecognitionTime == null ||
            now.difference(_lastRecognitionTime!) > _recognitionCooldown;

        if (canSendRecognition) {
          _lastRecognizedPerson = matchResult.name;
          _lastRecognitionTime = now;

          unawaited(_sendToSheet(_knownPersons[matchResult.name]!, matchResult.distance));
        }
      }
    } catch (e) {
      if (kDebugMode) print('Processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  _MatchResult _findBestMatch(List<double> embedding) {
    String bestName = 'Unknown';
    double bestDist = double.infinity;

    _knownPersons.forEach((name, person) {
      final distance = _cosineDistance(embedding, person.embedding);
      if (distance < bestDist) {
        bestDist = distance;
        bestName = name;
      }
    });

    return _MatchResult(
      name: bestDist <= _recognitionThreshold ? bestName : 'Unknown',
      distance: bestDist,
    );
  }

  Future<void> _sendToSheet(PersonData person, double distance) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = {
      'id': person.id,
      'name': person.name,
      'department': person.department,
      'section': person.section,
      'distance': distance,
      'timestamp': now,
    };

    try {
      final resp = await http.post(
        _sheetUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 5));

      if (resp.statusCode != 200) {
        if (kDebugMode) {
          print('Sheet error (${resp.statusCode}): ${resp.body}');
        }
      }
    } catch (e) {
      if (kDebugMode) print('HTTP error: $e');
    }
  }

  double _cosineDistance(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have the same dimensions');
    }

    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA <= 0 || normB <= 0) return 1.0;

    return 1 - (dot / (sqrt(normA) * sqrt(normB)));
  }

  img.Image _convertCameraImageToImage(CameraImage cameraImage) {
    if (cameraImage.format.group == ImageFormatGroup.yuv420) {
      return _convertYUV420toImage(cameraImage);
    } else if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
      return _convertBGRA8888ToImage(cameraImage);
    } else {
      throw Exception('Unsupported image format: ${cameraImage.format.group}');
    }
  }

  img.Image _convertYUV420toImage(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final outputImage = img.Image(width: width, height: height);

    final yPlane = image.planes[0].bytes;
    final uPlane = image.planes[1].bytes;
    final vPlane = image.planes[2].bytes;

    final yRowStride = image.planes[0].bytesPerRow;
    final uRowStride = image.planes[1].bytesPerRow;
    final vRowStride = image.planes[2].bytesPerRow;

    final uvPixelStride = image.planes[1].bytesPerPixel!;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yRowStride + x;
        final uvY = (y / 2).floor();
        final uvX = (x / 2).floor();
        final uvIndex = uvY * uRowStride + uvX * uvPixelStride;

        final yValue = yPlane[yIndex];
        final uValue = uPlane[uvIndex];
        final vValue = vPlane[uvIndex];

        int r = (yValue + 1.370705 * (vValue - 128)).round().clamp(0, 255);
        int g = (yValue - 0.337633 * (uValue - 128) - 0.698001 * (vValue - 128))
            .round()
            .clamp(0, 255);
        int b = (yValue + 1.732446 * (uValue - 128)).round().clamp(0, 255);

        outputImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    return outputImage;
  }

  img.Image _convertBGRA8888ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final planeData = image.planes[0].bytes;
    final pixelStride = image.planes[0].bytesPerPixel!;
    final outputImage = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final pixelIndex = (y * image.planes[0].bytesPerRow) + (x * pixelStride);

        final b = planeData[pixelIndex];
        final g = planeData[pixelIndex + 1];
        final r = planeData[pixelIndex + 2];
        final a = planeData[pixelIndex + 3];

        outputImage.setPixelRgba(x, y, r, g, b, a);
      }
    }

    return outputImage;
  }

  Future<void> _refreshData() async {
    setState(() {
      _statusMessage = 'Refreshing data...';
    });

    await _loadSavedData();

    setState(() {
      _statusMessage = 'Ready';
    });
  }

  @override
  void dispose() {
    _stopCamera();
    _fallbackTimer?.cancel();
    _cameraController?.dispose();
    _interpreter?.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Face Recognition'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshData,
            tooltip: 'Refresh data',
          ),
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: () {
              if (Platform.isWindows) {
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/home',
                      (route) => false,
                );
              } else {
                Navigator.pushNamed(context, '/home');
              }
            },
            tooltip: 'Go to home',
          ),
        ],
      ),
      body: Stack(
        children: [
          if (!_isInitialized)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    _statusMessage,
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            )
          else if (_cameraController != null && _cameraController!.value.isInitialized)
            Positioned.fill(
              child: AspectRatio(
                aspectRatio: _cameraController!.value.aspectRatio,
                child: CameraPreview(_cameraController!),
              ),
            )
          else
            const Center(
              child: Text(
                'Camera unavailable',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(200),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _predictedName.isEmpty ? 'Scanning...' : _predictedName,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _predictedName.contains('Unknown')
                          ? Colors.grey
                          : Colors.greenAccent,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Known persons: ${_knownPersons.length}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MatchResult {
  final String name;
  final double distance;

  const _MatchResult({
    required this.name,
    required this.distance,
  });
}

extension FutureExtensions<T> on Future<T> {
  void unawaited() {}
}
