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

/// Camera configuration constants
const _kResolutionPreset = ResolutionPreset.medium;
const _kInferenceDelay = Duration(milliseconds: 500);
const _kThreshold = 0.20;
const _kFallbackTimerDuration = Duration(milliseconds: 500);

/// UI-related constants
const _kThumbnailSize = 128;
const _kModelInputSize = 112;
const _kPreviewThumbSize = 80.0;

/// An enrollment screen with real-time face embedding and Windows fallback capture.
class RegisterStudent extends StatefulWidget {
  const RegisterStudent({super.key});

  @override
  RegisterStudentState createState() => RegisterStudentState();
}

class RegisterStudentState extends State<RegisterStudent> with WidgetsBindingObserver {
  // Camera and ML
  CameraController? _cameraController;
  Interpreter? _interpreter;
  bool _isProcessing = false;
  Timer? _fallbackTimer;
  DateTime? _lastInference;
  bool _cameraInitialized = false;
  bool _modelLoaded = false;
  String _errorMessage = '';

  // Image processing
  img.Image? _lastFrameImage;
  List<double>? _lastEmbedding;

  // Storage and data
  final StorageService _storage = StorageService();
  final Map<String, PersonData> _knownPersons = {};
  final Map<String, Uint8List> _knownThumbnails = {};

  // Recognition results
  String _predictedName = 'Unknown';
  double _confidence = 0.0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes to properly manage camera resources
    if (_cameraController == null) return;

    // When app is inactive or paused, release camera resources
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      // When app is resumed, reinitialize camera
      _initCamera();
    }
  }

  Future<void> _initialize() async {
    try {
      setState(() => _isLoading = true);

      // Run initialization tasks in parallel for better performance
      await Future.wait([
        _loadModel(),
        _loadSavedData(),
      ]);

      // Camera initialization after model and data are loaded
      await _initCamera();

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() {
        _errorMessage = 'Initialization error: $e';
        _isLoading = false;
      });
      debugPrint('Initialization error: $e');
    }
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/model/mobilefacenet.tflite',
        options: InterpreterOptions()..threads = 4, // Use multithreading
      );
      setState(() => _modelLoaded = true);
    } catch (e) {
      setState(() => _errorMessage = 'Failed to load model: $e');
      debugPrint('Model load error: $e');
    }
  }

  Future<void> _initCamera() async {
    try {
      // Dispose of any existing controller
      await _stopCamera();

      // Get available cameras
      final cameras = await CameraPlatform.instance.availableCameras();
      if (cameras.isEmpty) {
        setState(() => _errorMessage = 'No cameras available');
        return;
      }

      // Try to find front camera, fall back to first camera
      final camera = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      // Initialize controller with selected camera
      _cameraController = CameraController(
        camera,
        _kResolutionPreset,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();

      // Configure image streaming or fallback mechanism
      if (_cameraController!.value.isInitialized) {
        if (_cameraController!.supportsImageStreaming()) {
          await _cameraController!.startImageStream(_onFrameAvailable);
        } else {
          debugPrint('Image streaming not supported; using fallback capture.');
          _fallbackTimer = Timer.periodic(_kFallbackTimerDuration, _onFallbackTimer);
        }
        setState(() => _cameraInitialized = true);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Camera initialization error: $e');
      debugPrint('Camera initialization error: $e');
    }
  }

  Future<void> _stopCamera() async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;

    if (_cameraController != null) {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController!.dispose();
      _cameraController = null;
    }

    setState(() => _cameraInitialized = false);
  }

  void _onFallbackTimer(Timer timer) async {
    if (_isProcessing || !_cameraInitialized || _cameraController == null) return;

    try {
      _isProcessing = true;
      final XFile file = await _cameraController!.takePicture();
      final bytes = await File(file.path).readAsBytes();
      final frame = img.decodeImage(bytes);
      if (frame != null) {
        _processFrame(frame);
      }
      File(file.path).delete().catchError((e) => debugPrint('Error deleting temp file: $e'));
    } catch (e) {
      debugPrint('Fallback capture error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _loadSavedData() async {
    try {
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
    } catch (e) {
      debugPrint('Error loading saved data: $e');
    }
  }

  void _onFrameAvailable(CameraImage image) async {
    if (_isProcessing || _interpreter == null) return;

    // Rate-limit inference to avoid overloading the device
    if (_lastInference != null &&
        DateTime.now().difference(_lastInference!) < _kInferenceDelay) {
      return;
    }

    _isProcessing = true;
    _lastInference = DateTime.now();

    try {
      final rgb = _convertYUV420toImage(image);
      _processFrame(rgb);
    } catch (e) {
      debugPrint('Frame processing error: $e');
    } finally {
      _isProcessing = false;
    }
  }

  void _processFrame(img.Image rgb) async {
    try {
      _lastFrameImage = rgb;

      // Resize & normalize
      final resized = img.copyResize(rgb, width: _kModelInputSize, height: _kModelInputSize);
      final input = _prepareModelInput(resized);

      // Run inference
      final output = _runInference(input);
      _lastEmbedding = List<double>.from(output[0] as List);

      // Find best match
      final (name, distance) = _findBestMatch(_lastEmbedding!);

      setState(() {
        _predictedName = name;
        _confidence = 1.0 - distance; // Convert distance to confidence (0-1)
      });
    } catch (e) {
      debugPrint('Processing error: $e');
    }
  }

  List _prepareModelInput(img.Image resized) {
    // Create and populate normalized input tensor
    return List.generate(
      1,
          (_) => List.generate(
        _kModelInputSize,
            (y) => List.generate(_kModelInputSize, (x) {
          final p = resized.getPixel(x, y);
          // Normalize to [-1, 1] range
          return [
            (p.r - 127.5) / 127.5,
            (p.g - 127.5) / 127.5,
            (p.b - 127.5) / 127.5,
          ];
        }),
      ),
    );
  }

  List _runInference(List input) {
    final shape = _interpreter!.getOutputTensor(0).shape;
    final output = List.filled(shape[1], 0.0).reshape([1, shape[1]]);
    _interpreter!.run(input, output);
    return output;
  }

  (String, double) _findBestMatch(List<double> embedding) {
    String bestName = 'Unknown';
    double bestDist = double.infinity;

    for (var entry in _knownPersons.entries) {
      final d = _cosineDistance(embedding, entry.value.embedding);
      if (d < bestDist) {
        bestDist = d;
        bestName = entry.key;
      }
    }

    // Apply threshold for recognition
    if (bestDist > _kThreshold) {
      bestName = 'Unknown';
    }

    return (bestName, bestDist);
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
    if (_lastEmbedding == null || _lastFrameImage == null) {
      _showMessage('No face detected. Please position your face in the camera.');
      return;
    }

    final data = await _askForPersonDetails();
    if (data == null) return;

    try {
      // Create person data object
      final person = PersonData(
        name: data['name']!,
        id: data['id']!,
        department: data['department']!,
        section: data['section']!,
        embedding: List.from(_lastEmbedding!),
      );

      // Generate thumbnail
      final thumbImg = img.copyResize(
          _lastFrameImage!,
          width: _kThumbnailSize,
          height: _kThumbnailSize
      );
      final pngBytes = Uint8List.fromList(img.encodePng(thumbImg));

      // Update collections
      _knownPersons[person.name] = person;
      _knownThumbnails[person.name] = pngBytes;

      // Save to storage
      await _storage.saveKnownPersons(_knownPersons);
      await _storage.saveThumbnail(person.name, pngBytes);

      setState(() {});
      _showMessage('${person.name} enrolled successfully!');
    } catch (e) {
      _showMessage('Error saving person: $e');
      debugPrint('Error saving person: $e');
    }
  }

  Future<void> _deletePerson(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete $name?'),
        content: Text('Are you sure you want to remove $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      _knownPersons.remove(name);
      _knownThumbnails.remove(name);
      await _storage.saveKnownPersons(_knownPersons);
      await _storage.deleteThumbnail(name);

      setState(() {});
      _showMessage('$name removed.');
    } catch (e) {
      _showMessage('Error deleting person: $e');
      debugPrint('Error deleting person: $e');
    }
  }

  Future<Map<String, String>?> _askForPersonDetails() async {
    final formKey = GlobalKey<FormState>();
    final data = {'name': '', 'id': '', 'department': '', 'section': ''};

    return showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text('Add Person'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: ['Name', 'ID', 'Department', 'Section'].map((field) {
              final key = field.toLowerCase();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: TextFormField(
                  onChanged: (v) => data[key] = v,
                  validator: (v) => v!.isEmpty ? '$field is required' : null,
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
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, data);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // Optimized YUV420 to RGB conversion
  img.Image _convertYUV420toImage(CameraImage image) {
    final w = image.width, h = image.height;
    final out = img.Image(width: w, height: h);
    final y = image.planes[0].bytes;
    final u = image.planes[1].bytes;
    final v = image.planes[2].bytes;
    final us = image.planes[1].bytesPerRow;
    final vs = image.planes[2].bytesPerRow;
    final pix = image.planes[1].bytesPerPixel!;

    // Use efficient byte conversions with precalculated values where possible
    for (var i = 0; i < h; i++) {
      for (var j = 0; j < w; j++) {
        final yi = i * image.planes[0].bytesPerRow + j;
        final yv = y[yi] & 0xFF;
        final uIdx = (i >> 1) * us + (j >> 1) * pix;
        final vIdx = (i >> 1) * vs + (j >> 1) * pix;
        final uvU = u[uIdx] & 0xFF;
        final uvV = v[vIdx] & 0xFF;

        final uvUdiff = uvU - 128;
        final uvVdiff = uvV - 128;

        int r = (yv + 1.370705 * uvVdiff).toInt();
        int g = (yv - 0.337633 * uvUdiff - 0.698001 * uvVdiff).toInt();
        int b = (yv + 1.732446 * uvUdiff).toInt();

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
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    _cameraController?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage.isNotEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('Error'),
          backgroundColor: Colors.black,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                _errorMessage,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _initialize,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

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
            icon: const Icon(Icons.home),
            tooltip: 'Return to Home',
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
            tooltip: 'Reload Student Data',
            onPressed: _loadSavedData,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return Stack(
      children: [
        // Camera Preview
        Positioned.fill(
          child: CameraPreview(_cameraController!),
        ),

        // Known Persons List
        _buildPersonsList(),

        // Recognition Results Panel
        _buildRecognitionPanel(),
      ],
    );
  }

  Widget _buildPersonsList() {
    return Positioned(
      bottom: 140,
      left: 16,
      right: 16,
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
        ),
        child: _knownThumbnails.isEmpty
            ? const Center(
          child: Text(
            'No students registered yet.\nTap + button to add a student.',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        )
            : ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(8),
          itemCount: _knownThumbnails.length,
          itemBuilder: (context, index) {
            final name = _knownThumbnails.keys.elementAt(index);
            final bytes = _knownThumbnails[name]!;
            return _buildPersonThumbnail(name, bytes);
          },
        ),
      ),
    );
  }

  Widget _buildPersonThumbnail(String name, Uint8List bytes) {
    final person = _knownPersons[name];
    final isSelected = _predictedName == name;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        children: [
          Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isSelected
                      ? Border.all(color: Colors.greenAccent, width: 2)
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    bytes,
                    width: _kPreviewThumbSize,
                    height: _kPreviewThumbSize,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              Positioned(
                top: -4,
                right: -4,
                child: GestureDetector(
                  onTap: () => _deletePerson(name),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
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
            style: TextStyle(
              color: isSelected ? Colors.greenAccent : Colors.white,
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (person != null)
            Text(
              person.id,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecognitionPanel() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.person,
                      color: Colors.white70,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _predictedName,
                      style: TextStyle(
                        color: _predictedName != 'Unknown'
                            ? Colors.greenAccent
                            : Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_predictedName != 'Unknown')
                  _buildConfidenceBar(_confidence),
              ],
            ),
            FloatingActionButton(
              backgroundColor: Colors.blueAccent,
              onPressed: _addPerson,
              tooltip: 'Add New Student',
              child: const Icon(Icons.person_add),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfidenceBar(double confidence) {
    final displayConfidence = (confidence * 100).toStringAsFixed(1);
    Color barColor;

    // Color based on confidence level
    if (confidence > 0.8) {
      barColor = Colors.green;
    } else if (confidence > 0.6) {
      barColor = Colors.amber;
    } else {
      barColor = Colors.redAccent;
    }

    return Row(
      children: [
        const Text(
          'Confidence: ',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(width: 4),
        Container(
          width: 100,
          height: 6,
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(3),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: confidence.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$displayConfidence%',
          style: TextStyle(color: barColor, fontSize: 12),
        ),
      ],
    );
  }
}