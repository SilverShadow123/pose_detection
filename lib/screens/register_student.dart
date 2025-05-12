import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/person_data.dart';
import '../services/storage_service.dart';

/// An enrollment screen with real-time face embedding and Windows fallback capture.
class RegisterStudent extends StatefulWidget {
  const RegisterStudent({super.key});

  @override
  RegisterStudentState createState() => RegisterStudentState();
}

class RegisterStudentState extends State<RegisterStudent> {
  CameraController? _cameraController;
  Interpreter? _interpreter;
  bool _isProcessing = false;
  Timer? _fallbackTimer;
  DateTime? _lastInference;

  img.Image? _lastFrameImage;
  List<double>? _lastEmbedding;

  final StorageService _storage = StorageService();
  final Map<String, PersonData> _knownPersons = {};
  final Map<String, Uint8List> _knownThumbnails = {};

  String _predictedName = '';
  final double _threshold = 0.20;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Load model
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/model/mobilefacenet.tflite',
      );
    } catch (e) {
      debugPrint('Model load error: $e');
      return;
    }
    // Init camera
    await _initCamera();
    // Load stored data
    await _loadSavedData();
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

    // Use streaming if supported, else fallback on Windows
    if (_cameraController!.supportsImageStreaming()) {
      _cameraController!.startImageStream(_onFrameAvailable);
    } else {
      debugPrint('Image streaming not supported; using fallback capture.');
      _fallbackTimer = Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) async {
        if (_isProcessing) return;
        try {
          final XFile file = await _cameraController!.takePicture();
          final bytes = await File(file.path).readAsBytes();
          final frame = img.decodeImage(bytes);
          if (frame != null) {
            _processFrame(frame);
          }
        } catch (e) {
          debugPrint('Fallback capture error: $e');
        }
      });
    }
    setState(() {});
  }

  Future<void> _loadSavedData() async {
    final persons = await _storage.loadKnownPersons();
    final thumbs = await _storage.loadThumbnails(persons.keys.toList());
    setState(() {
      _knownPersons
        ..clear()
        ..addAll(persons);
      _knownThumbnails
        ..clear()
        ..addAll(thumbs);
    });
  }

  void _onFrameAvailable(CameraImage image) async {
    if (_isProcessing || _interpreter == null) return;
    if (_lastInference != null &&
        DateTime.now().difference(_lastInference!) <
            Duration(milliseconds: 500)) {
      return;
    }
    _lastInference = DateTime.now();
    try {
      final rgb = _convertYUV420toImage(image);
      _processFrame(rgb);
    } catch (e) {
      debugPrint('Frame processing error: $e');
    }
  }

  void _processFrame(img.Image rgb) async {
    _isProcessing = true;
    try {
      _lastFrameImage = rgb;
      // Resize & normalize
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

      final shape = _interpreter!.getOutputTensor(0).shape;
      final output = List.filled(shape[1], 0.0).reshape([1, shape[1]]);
      _interpreter!.run(input, output);
      _lastEmbedding = List<double>.from(output[0] as List);

      // Find best match
      String bestName = 'Unknown';
      double bestDist = double.infinity;
      for (var entry in _knownPersons.entries) {
        final d = _cosineDistance(_lastEmbedding!, entry.value.embedding);
        if (d < bestDist) {
          bestDist = d;
          bestName = entry.key;
        }
      }
      if (bestDist > _threshold) bestName = 'Unknown';

      setState(
        () => _predictedName = '$bestName (${bestDist.toStringAsFixed(2)})',
      );
    } catch (e) {
      debugPrint('Processing error: $e');
    }
    _isProcessing = false;
  }

  double _cosineDistance(List<double> a, List<double> b) {
    double dot = 0, na = 0, nb = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    return 1 - (dot / (sqrt(na) * sqrt(nb)));
  }

  Future<void> _addPerson() async {
    if (_lastEmbedding == null || _lastFrameImage == null) return;
    final data = await _askForPersonDetails();
    if (data == null) return;

    final person = PersonData(
      name: data['name']!,
      id: data['id']!,
      department: data['department']!,
      section: data['section']!,
      embedding: List.from(_lastEmbedding!),
    );
    _knownPersons[person.name] = person;

    final thumbImg = img.copyResize(_lastFrameImage!, width: 128, height: 128);
    final pngBytes = Uint8List.fromList(img.encodePng(thumbImg));
    _knownThumbnails[person.name] = pngBytes;

    await _storage.saveKnownPersons(_knownPersons);
    await _storage.saveThumbnail(person.name, pngBytes);

    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${person.name} enrolled successfully!')),
      );
    }
  }

  Future<void> _deletePerson(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (_) => AlertDialog(
            title: Text('Delete $name?'),
            content: Text('Are you sure you want to remove $name?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Delete'),
              ),
            ],
          ),
    );
    if (confirm != true) return;

    _knownPersons.remove(name);
    _knownThumbnails.remove(name);
    await _storage.saveKnownPersons(_knownPersons);
    await _storage.deleteThumbnail(name);

    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$name removed.')));
    }
  }

  Future<Map<String, String>?> _askForPersonDetails() async {
    final formKey = GlobalKey<FormState>();
    final data = {'name': '', 'id': '', 'department': '', 'section': ''};
    return showDialog<Map<String, String>>(
      context: context,
      builder:
          (_) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text('Add Person'),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children:
                    ['Name', 'ID', 'Department', 'Section'].map((field) {
                      final key = field.toLowerCase();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: TextFormField(
                          onChanged: (v) => data[key] = v,
                          validator:
                              (v) => v!.isEmpty ? '$field is required' : null,
                          decoration: InputDecoration(
                            labelText: field,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (formKey.currentState!.validate()) {
                    Navigator.pop(context, data);
                  }
                },
                child: Text('Save'),
              ),
            ],
          ),
    );
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
        title: const Text('Register Student'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
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
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadSavedData(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: CameraPreview(_cameraController!)),
          Positioned(
            bottom: 140,
            left: 16,
            right: 16,
            child: Container(
              height: 140,
              decoration: BoxDecoration(
                color: Colors.black54,
                boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 4)],
              ),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(8),
                itemCount: _knownThumbnails.length,
                itemBuilder: (context, index) {
                  final name = _knownThumbnails.keys.elementAt(index);
                  final bytes = _knownThumbnails[name]!;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                bytes,
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              top: -4,
                              right: -4,
                              child: GestureDetector(
                                onTap: () => _deletePerson(name),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black87,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _predictedName,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  FloatingActionButton(
                    backgroundColor: Colors.blueAccent,
                    onPressed: _addPerson,
                    child: const Icon(Icons.person_add),
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
