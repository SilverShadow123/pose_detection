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

class RealtimeFaceRecognitionState extends State<RealtimeFaceRecognition> {
  CameraController? _cameraController;
  Interpreter? _interpreter;
  bool _isProcessing = false;
  Timer? _fallbackTimer;

  img.Image? _lastFrameImage;
  List<double>? _lastEmbedding;

  final Map<String, PersonData> _knownPersons = {};

  String _predictedName = '';
  String? _lastSentName;
  final _sheetUrl = Uri.parse(
    'https://script.google.com/macros/s/AKfycbzC6cXfECGqTfVRiADOcGlMk913In_bPCzC9R1rkWcJWS0UX7pi160_eH_Fgjtw3InB/exec',
  );

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _loadModel();
    await _initCamera();
    await _loadSavedData();
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/model/mobilefacenet.tflite',
      );
    } catch (e) {
      if (kDebugMode) print('Model loading error: $e');
    }
  }

  Future<void> _initCamera() async {
    final cameras = await CameraPlatform.instance.availableCameras();
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await _cameraController!.initialize();

    // Use streaming if supported, otherwise fallback to periodic capture on Windows
    if (_cameraController!.supportsImageStreaming()) {
      _cameraController!.startImageStream(_onFrameAvailable);
    } else {
      if (kDebugMode) {
        print(
          'Image streaming not supported on this platform, using fallback capture.',
        );
      }
      _fallbackTimer = Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) async {
        try {
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

    setState(() {});
  }

  Future<void> _loadSavedData() async {
    final persons = await StorageService().loadKnownPersons();
    setState(() {
      _knownPersons.clear();
      _knownPersons.addAll(persons);
    });
  }

  void _onFrameAvailable(CameraImage image) async {
    if (_isProcessing || _interpreter == null) return;
    try {
      final frame = _convertYUV420toImage(image);
      _processFrame(frame);
    } catch (e) {
      if (kDebugMode) print('Frame processing error: $e');
    }
  }

  void _processFrame(img.Image rgb) async {
    _isProcessing = true;
    try {
      _lastFrameImage = rgb;
      final resized = img.copyResize(rgb, width: 112, height: 112);
      final input = List.generate(
        1,
        (_) => List.generate(
          112,
          (y) => List.generate(112, (x) {
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
      final out = List.filled(shape[1], 0.0).reshape([1, shape[1]]);
      _interpreter!.run(input, out);
      _lastEmbedding = List<double>.from(out[0] as List);

      String bestName = 'Unknown';
      double bestDist = double.infinity;
      _knownPersons.forEach((name, person) {
        final d = _cosineDistance(_lastEmbedding!, person.embedding);
        if (d < bestDist) {
          bestDist = d;
          bestName = name;
        }
      });
      if (bestDist > 0.20) bestName = 'Unknown';

      setState(
        () => _predictedName = '$bestName (${bestDist.toStringAsFixed(2)})',
      );

      if (bestName != 'Unknown' &&
          bestName != _lastSentName &&
          bestDist <= 0.20) {
        _lastSentName = bestName;
        _sendToSheet(bestName, bestDist);
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _sendToSheet(String name, double dist) async {
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      final resp = await http.post(
        _sheetUrl,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'distance': dist, 'timestamp': now}),
      );
      if (resp.statusCode != 200 && kDebugMode) {
        print('Sheet error ${resp.body}');
      }
    } catch (e) {
      if (kDebugMode) print('HTTP error $e');
    }
  }

  double _cosineDistance(List<double> a, List<double> b) {
    double dot = 0, na = 0, nb = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return 1 - (dot / (sqrt(na) * sqrt(nb)));
  }

  img.Image _convertYUV420toImage(CameraImage image) {
    final w = image.width, h = image.height;
    final out = img.Image(width: w, height: h);
    final y = image.planes[0].bytes;
    final u = image.planes[1].bytes;
    final v = image.planes[2].bytes;
    final us = image.planes[1].bytesPerRow;
    final vs = image.planes[2].bytesPerRow;
    final pix = image.planes[1].bytesPerPixel!;
    for (var i = 0; i < h; i++) {
      for (var j = 0; j < w; j++) {
        final yi = i * image.planes[0].bytesPerRow + j;
        final yv = y[yi] & 0xFF;
        final uIdx = (i >> 1) * us + (j >> 1) * pix;
        final vIdx = (i >> 1) * vs + (j >> 1) * pix;
        final uvU = u[uIdx] & 0xFF;
        final uvV = v[vIdx] & 0xFF;
        int r = (yv + 1.370705 * (uvV - 128)).toInt();
        int g = (yv - 0.337633 * (uvU - 128) - 0.698001 * (uvV - 128)).toInt();
        int b = (yv + 1.732446 * (uvU - 128)).toInt();
        out.setPixelRgba(
          j,
          i,
          r.clamp(0, 255),
          g.clamp(0, 255),
          b.clamp(0, 255),
          255,
        );
      }
    }
    return out;
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    _cameraController?.dispose();
    _interpreter?.close();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Real-time Face Recognition'),
        actions: [
          IconButton(
            onPressed:
                () => Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/home',
                  (route) => false,
                ),
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async => _loadSavedData(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: CameraPreview(_cameraController!)),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              color: Colors.black87,
              child: Text(
                _predictedName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
