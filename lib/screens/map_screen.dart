import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../services/location_service.dart';
import '../services/aggregation_service.dart';
import '../services/lora_companion_service.dart';
import '../services/database_service.dart';
import '../services/upload_service.dart';
import '../services/settings_service.dart';
import '../utils/geohash_utils.dart';
import 'package:geohash_plus/geohash_plus.dart' as geohash;
import 'package:usb_serial/usb_serial.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'debug_log_screen.dart';
import 'debug_diagnostics_screen.dart';
import '../main.dart';
import '../constants/app_version.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // App version is imported from constants/app_version.dart
  static const double _tabletBreakpoint = 600;
  
  final LocationService _locationService = LocationService();
  final MapController _mapController = MapController();
  final UploadService _uploadService = UploadService();
  final SettingsService _settingsService = SettingsService();
  
  bool _isTracking = false;
  int _sampleCount = 0;
  List<Sample> _samples = [];
  AggregationResult? _aggregationResult;
  
  String _colorMode = 'quality';
  bool _showSamples = false;
  bool _showGpsSamples = true; // Show GPS-only samples (null pingSuccess)
  bool _showSuccessfulOnly = false; // Show only samples with successful pings
  bool _showCoverage = true; // Show coverage boxes
  bool _showEdges = true;
  bool _showRepeaters = true;
  bool _autoPingEnabled = false;
  String? _ignoredRepeaterPrefix;
  String? _includeOnlyRepeaters; // Comma-separated list of repeater prefixes to show
  double _pingIntervalMeters = 805.0; // Default 0.5 miles
  int _coveragePrecision = 6; // Default precision 6 (~1.2km squares)
  
  // Repeaters
  List<Repeater> _repeaters = [];
  
  LatLng? _currentPosition;
  Timer? _updateTimer;
  StreamSubscription<LatLng>? _positionSubscription;
  StreamSubscription<void>? _sampleSavedSubscription;
  StreamSubscription<String>? _pingEventSubscription;
  
  // Ping visual indicator
  bool _showPingPulse = false;
  
  // LoRa connection status
  bool _loraConnected = false;
  ConnectionType _connectionType = ConnectionType.none;
  int? _batteryPercent;
  StreamSubscription<int?>? _batterySubscription;
  
  // Auto-follow GPS location
  bool _followLocation = false;
  
  // Map rotation lock
  bool _lockRotationNorth = false;

  bool _isTabletWidth(BuildContext context) {
    return MediaQuery.sizeOf(context).shortestSide >= _tabletBreakpoint;
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Load saved settings
    await _loadSettings();
    
    // Subscribe to battery updates
    final loraService = _locationService.loraCompanion;
    _batterySubscription = loraService.batteryStream.listen((percent) {
      setState(() {
        _batteryPercent = percent;
      });
    });
    
    // Subscribe to position updates
    _positionSubscription = _locationService.currentPositionStream.listen((position) {
      setState(() {
        _currentPosition = position;
      });
      
      // Auto-follow if enabled
      if (_followLocation && position != null) {
        _mapController.move(position, _mapController.camera.zoom);
      }
    });
    
    // Subscribe to sample saved events - reload map when new samples are saved
    _sampleSavedSubscription = _locationService.sampleSavedStream.listen((_) {
      _loadSamples();
    });
    
    // Subscribe to ping events for visual feedback
    _pingEventSubscription = _locationService.pingEventStream.listen((event) {
      if (event == 'pinging' && mounted) {
        setState(() {
          _showPingPulse = true;
        });
        // Hide pulse after 2 seconds
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _showPingPulse = false;
            });
          }
        });
      }
    });
    
    await _loadSamples();
    await _getCurrentLocation();
    
    // Update periodically
    _updateTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadSamples();
    });
  }
  
  Future<void> _loadSettings() async {
    final showSamples = await _settingsService.getShowSamples();
    final showGpsSamples = await _settingsService.getShowGpsSamples();
    final showCoverage = await _settingsService.getShowCoverage();
    final showEdges = await _settingsService.getShowEdges();
    final showRepeaters = await _settingsService.getShowRepeaters();
    final colorMode = await _settingsService.getColorMode();
    final pingInterval = await _settingsService.getPingInterval();
    final coveragePrecision = await _settingsService.getCoveragePrecision();
    final ignoredPrefix = await _settingsService.getIgnoredRepeaterPrefix();
    final includeOnly = await _settingsService.getIncludeOnlyRepeaters();
    
    setState(() {
      _showSamples = showSamples;
      _showGpsSamples = showGpsSamples;
      _showCoverage = showCoverage;
      _showEdges = showEdges;
      _showRepeaters = showRepeaters;
      _colorMode = colorMode;
      _pingIntervalMeters = pingInterval;
      _coveragePrecision = coveragePrecision;
      _ignoredRepeaterPrefix = ignoredPrefix;
      _includeOnlyRepeaters = includeOnly;
    });
    
    // Apply to services
    _locationService.setPingInterval(pingInterval);
    _locationService.loraCompanion.setIgnoredRepeaterPrefix(ignoredPrefix);
  }

  Future<void> _getCurrentLocation() async {
    final pos = await _locationService.getCurrentPosition();
    if (pos != null) {
      setState(() {
        _currentPosition = pos;
      });
      // Move map to user's current location on startup
      _mapController.move(pos, 13.0);
    }
  }

  Future<void> _loadSamples() async {
    final samples = await _locationService.getAllSamples();
    final count = await _locationService.getSampleCount();
    
    // Update connection status
    final loraService = _locationService.loraCompanion;
    
    // Sync discovered repeaters from LoRa service
    final discoveredRepeaters = loraService.discoveredRepeaters;
    
    // Aggregate data with user's chosen coverage precision and repeaters
    final result = AggregationService.buildIndexes(
      samples, 
      discoveredRepeaters,
      coveragePrecision: _coveragePrecision,
    );
    
    setState(() {
      _samples = samples;
      _sampleCount = count;
      _aggregationResult = result;
      _loraConnected = loraService.isDeviceConnected;
      _connectionType = loraService.connectionType;
      _autoPingEnabled = _locationService.isAutoPingEnabled;
      _repeaters = discoveredRepeaters;
    });
  }

  Future<void> _toggleTracking() async {
    if (_isTracking) {
      // Stop tracking and auto-ping
      await _locationService.stopTracking();
      _locationService.disableAutoPing();
      setState(() {
        _isTracking = false;
        _autoPingEnabled = false;
      });
    } else {
      // Start tracking
      final started = await _locationService.startTracking();
      if (started) {
        // Auto-enable ping if LoRa is connected
        if (_loraConnected) {
          _locationService.enableAutoPing();
          setState(() {
            _isTracking = true;
            _autoPingEnabled = true;
          });
          _showSnackBar('Location tracking and auto-ping started');
        } else {
          setState(() {
            _isTracking = true;
          });
          _showSnackBar('Location tracking started');
        }
      } else {
        _showSnackBar('Failed to start tracking. Check permissions.');
      }
    }
  }

  Future<void> _clearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Map History'),
        content: const Text('This will delete all recorded samples and coverage from the map. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _locationService.clearAllSamples();
      await _loadSamples();
      _showSnackBar('Map history cleared');
    }
  }

  Future<void> _exportData() async {
    // Ask user if they want to save to folder or share
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export Data'),
        content: const Text('How would you like to export your data?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save to Folder'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'share'),
            child: const Text('Share'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    
    if (choice == null) return;
    
    try {
      final data = await _locationService.exportSamples();
      final json = jsonEncode(data);
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = 'meshcore_export_$timestamp.json';
      
      if (choice == 'save') {
        // Let user choose where to save (provide bytes for Android/iOS)
        final outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Export',
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: ['json'],
          bytes: utf8.encode(json), // Required on Android/iOS
        );
        
        if (outputFile != null) {
          _showSnackBar('Exported ${data.length} samples');
        }
      } else if (choice == 'share') {
        // Create temporary file and share
        final directory = await getExternalStorageDirectory();
        final file = File('${directory!.path}/$fileName');
        await file.writeAsString(json);
        
        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'MeshCore Wardrive Export',
          text: 'Exported ${data.length} samples from MeshCore Wardrive',
        );
        
        _showSnackBar('Export shared');
      }
    } catch (e) {
      _showSnackBar('Export failed: $e');
    }
  }

  Future<void> _importData() async {
    try {
      // Pick a JSON file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      
      if (result == null || result.files.single.path == null) {
        return; // User cancelled
      }
      
      final file = File(result.files.single.path!);
      final jsonString = await file.readAsString();
      final List<dynamic> jsonData = jsonDecode(jsonString);
      
      // Import samples
      final importedCount = await _locationService.importSamples(
        jsonData.cast<Map<String, dynamic>>(),
      );
      
      // Reload map
      await _loadSamples();
      
      _showSnackBar('Imported $importedCount new samples');
    } catch (e) {
      _showSnackBar('Import failed: $e');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
  
  Future<void> _checkForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/mintylinux/Meshcore-Wardrive-Android/releases/latest'),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tagName = data['tag_name'].toString();
        // Extract version from tag like "Meshcore-Wardrive-Android-1.0.2"
        final latestVersion = tagName.split('-').last;
        
        if (latestVersion != appVersion) {
          if (!mounted) return;
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Update Available'),
              content: Text(
                'New version $latestVersion is available!\n\n'
                'Current version: $appVersion\n\n'
                'Would you like to download it?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Later'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _openGitHub();
                  },
                  child: const Text('Download'),
                ),
              ],
            ),
          );
        } else {
          _showSnackBar('You\'re on the latest version!');
        }
      } else {
        _showSnackBar('Could not check for updates');
      }
    } catch (e) {
      _showSnackBar('Error checking for updates: $e');
    }
  }
  
  Future<void> _openGitHub() async {
    final url = Uri.parse('https://github.com/mintylinux/Meshcore-Wardrive-Android/releases');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      _showSnackBar('Could not open GitHub');
    }
  }
  

  void _toggleFollowLocation() {
    setState(() {
      _followLocation = !_followLocation;
    });
    
    if (_followLocation) {
      // Center on current location when enabling follow
      if (_currentPosition != null) {
        _mapController.move(_currentPosition!, _mapController.camera.zoom);
      }
      _showSnackBar('Auto-follow enabled');
    } else {
      _showSnackBar('Auto-follow disabled');
    }
  }
  
  void _resetMapRotation() {
    _mapController.rotate(0); // 0 degrees = north up
    _showSnackBar('Map reset to north');
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _batterySubscription?.cancel();
    _positionSubscription?.cancel();
    _sampleSavedSubscription?.cancel();
    _pingEventSubscription?.cancel();
    _locationService.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshCore Wardrive'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const DebugLogScreen()),
              );
            },
            tooltip: 'Debug Terminal',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildMap(),
          _buildControlPanel(),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'compass',
            mini: true,
            onPressed: _resetMapRotation,
            child: const Icon(Icons.navigation),
            tooltip: 'Reset to North',
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'location',
            mini: true,
            onPressed: _toggleFollowLocation,
            backgroundColor: _followLocation ? Colors.blue : null,
            child: Icon(
              _followLocation ? Icons.gps_fixed : Icons.gps_not_fixed,
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'tracking',
            onPressed: _toggleTracking,
            backgroundColor: _isTracking ? Colors.red : Colors.green,
            child: Icon(_isTracking ? Icons.stop : Icons.play_arrow),
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _currentPosition ?? GeohashUtils.centerPos,
        initialZoom: 13.0,
        minZoom: 3.0,
        maxZoom: 18.0,
        interactionOptions: InteractionOptions(
          flags: _lockRotationNorth 
              ? InteractiveFlag.all & ~InteractiveFlag.rotate  // Disable rotation
              : InteractiveFlag.all,  // Allow all interactions
        ),
        onMapEvent: (event) {
          // Disable follow mode if user manually pans/drags the map
          if (event is MapEventMoveStart && event.source == MapEventSource.mapController) {
            // Ignore programmatic moves (from auto-follow)
            return;
          }
          if (event is MapEventMoveStart && _followLocation) {
            setState(() {
              _followLocation = false;
            });
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: isDarkMode
              ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
              : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: isDarkMode ? const ['a', 'b', 'c', 'd'] : const [],
          userAgentPackageName: 'com.meshcore.wardrive',
        ),
        if (_showCoverage) ..._buildCoverageLayers(),
        if (_showSamples) _buildSampleLayer(),
        if (_showEdges) _buildEdgeLayer(),
        if (_showRepeaters) _buildRepeaterLayer(),
        if (_currentPosition != null) _buildCurrentLocationLayer(),
      ],
    );
  }

  List<Widget> _buildCoverageLayers() {
    if (_aggregationResult == null) return [];
    
    final coveragePolygons = <Polygon>[];
    final coverageMarkers = <Marker>[];
    
    for (final coverage in _aggregationResult!.coverages) {
      final gh = geohash.GeoHash.decode(coverage.id);
      final color = Color(AggregationService.getCoverageColor(coverage, _colorMode));
      final opacity = AggregationService.getCoverageOpacity(coverage);
      
      // Get corners from geohash bounds
      final sw = gh.bounds.southWest;
      final ne = gh.bounds.northEast;
      
      coveragePolygons.add(
        Polygon(
          points: [
            LatLng(sw.latitude, sw.longitude),
            LatLng(sw.latitude, ne.longitude),
            LatLng(ne.latitude, ne.longitude),
            LatLng(ne.latitude, sw.longitude),
          ],
          color: color.withValues(alpha: opacity),
          borderColor: color,
          borderStrokeWidth: 1,
          isFilled: true,
        ),
      );
      
      // Add invisible tap target at center of coverage square
      coverageMarkers.add(
        Marker(
          point: coverage.position,
          width: 100,
          height: 100,
          child: GestureDetector(
            onTap: () => _showCoverageInfo(coverage),
            child: Container(color: Colors.transparent),
          ),
        ),
      );
    }
    
    return [
      PolygonLayer(polygons: coveragePolygons),
      MarkerLayer(markers: coverageMarkers),
    ];
  }

  Widget _buildSampleLayer() {
    if (_samples.isEmpty) return const SizedBox.shrink();
    
    // Filter samples based on settings
    final filteredSamples = _samples.where((sample) {
      // If showing GPS samples is disabled, hide samples with null pingSuccess
      if (!_showGpsSamples && sample.pingSuccess == null) {
        return false;
      }
      
      // If showing successful only, hide failed pings and GPS-only samples
      if (_showSuccessfulOnly && sample.pingSuccess != true) {
        return false;
      }
      
      // If include-only repeaters is set, only show samples from those repeaters
      if (_includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty) {
        final allowedPrefixes = _includeOnlyRepeaters!.split(',').map((s) => s.trim().toUpperCase()).toList();
        final sampleNodeId = sample.path?.toUpperCase() ?? '';
        
        // Check if sample's repeater matches any allowed prefix
        final matches = allowedPrefixes.any((prefix) => sampleNodeId.startsWith(prefix));
        if (!matches) {
          return false;
        }
      }
      
      return true;
    }).toList();
    
    // Sort by timestamp (oldest first) so newer samples render on top
    filteredSamples.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    final markers = filteredSamples.map((sample) {
      // Determine color based on ping result
      Color markerColor;
      if (sample.pingSuccess == true) {
        markerColor = Colors.green; // Successful ping
      } else if (sample.pingSuccess == false) {
        markerColor = Colors.red; // Failed ping
      } else {
        markerColor = Colors.blue; // GPS-only sample
      }
      
      return Marker(
        point: sample.position,
        width: 12,
        height: 12,
        child: GestureDetector(
          onTap: () => _showSampleInfo(sample),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: markerColor.withValues(alpha: 0.7),
              shape: BoxShape.circle,
              border: Border.all(
                color: markerColor.withValues(alpha: 0.9),
                width: 1,
              ),
            ),
          ),
        ),
      );
    }).toList();
    
    return MarkerLayer(markers: markers);
  }

  Widget _buildEdgeLayer() {
    if (_aggregationResult == null) return const SizedBox.shrink();
    
    final polylines = _aggregationResult!.edges.map((edge) {
      return Polyline(
        points: [edge.coverage.position, edge.repeater.position],
        color: Colors.purple.withValues(alpha: 0.6),  // Increased from 0.3 to 0.6
        strokeWidth: 2,  // Increased from 1 to 2
      );
    }).toList();
    
    return PolylineLayer(polylines: polylines);
  }

  Widget _buildRepeaterLayer() {
    if (_repeaters.isEmpty) return const SizedBox.shrink();
    
    final markers = _repeaters.map((repeater) {
      return Marker(
        point: repeater.position,
        width: 30,
        height: 30,
        child: GestureDetector(
          onTap: () => _showRepeaterInfo(repeater),
          child: const Icon(
            Icons.cell_tower,
            color: Colors.purple,
            size: 30,
          ),
        ),
      );
    }).toList();
    
    return MarkerLayer(markers: markers);
  }

  Widget _buildCurrentLocationLayer() {
    final markers = [
      // Main location dot
      Marker(
        point: _currentPosition!,
        width: 20,
        height: 20,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    ];
    
    // Add ping pulse animation when auto-pinging
    if (_showPingPulse) {
      markers.add(
        Marker(
          point: _currentPosition!,
          width: 60,
          height: 60,
          child: TweenAnimationBuilder(
            tween: Tween<double>(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 1500),
            builder: (context, double value, child) {
              return Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 1.0 - value),
                    width: 3,
                  ),
                ),
              );
            },
          ),
        ),
      );
    }
    
    return MarkerLayer(markers: markers);
  }

  Widget _buildControlPanel() {
    if (_isTabletWidth(context)) {
      return Positioned(
        top: 16,
        left: 16,
        width: (MediaQuery.sizeOf(context).width - 32)
            .clamp(420.0, 640.0)
            .toDouble(),
        child: _buildTabletControlPanel(),
      );
    }

    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Connection Status
              Row(
                children: [
                  Icon(
                    _loraConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                    size: 16,
                    color: _loraConnected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _loraConnected 
                        ? (_connectionType == ConnectionType.usb ? 'USB' : 'BT')
                        : 'No LoRa',
                    style: TextStyle(
                      fontSize: 12,
                      color: _loraConnected ? Colors.green : Colors.grey,
                    ),
                  ),
                  if (_loraConnected && _batteryPercent != null)
                    const SizedBox(width: 4),
                  if (_loraConnected && _batteryPercent != null)
                    Icon(
                      _getBatteryIcon(_batteryPercent!),
                      size: 14,
                      color: _getBatteryColor(_batteryPercent!),
                    ),
                  if (_loraConnected && _batteryPercent != null)
                    const SizedBox(width: 2),
                  if (_loraConnected && _batteryPercent != null)
                    Text(
                      '$_batteryPercent%',
                      style: TextStyle(
                        fontSize: 11,
                        color: _getBatteryColor(_batteryPercent!),
                      ),
                    ),
                  const Spacer(),
                  if (!_loraConnected)
                    TextButton(
                      onPressed: _showConnectionDialog,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      child: const Text('Connect', style: TextStyle(fontSize: 12)),
                    ),
                  if (_loraConnected)
                    IconButton(
                      icon: const Icon(Icons.more_vert, size: 20),
                      onPressed: _disconnectLoRa,
                      tooltip: 'Disconnect',
                    ),
                  if (_loraConnected)
                    IconButton(
                      icon: const Icon(Icons.send, size: 20),
                      onPressed: _manualPing,
                      tooltip: 'Manual Ping',
                      color: Colors.blue,
                    ),
                ],
              ),
              const Divider(height: 16),
              // Stats
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Samples: $_sampleCount',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Coverage: ${_aggregationResult?.coverages.length ?? 0}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _exportData,
                      icon: const Icon(Icons.upload, size: 18),
                      label: const Text('Export'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _importData,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Import'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _clearData,
                icon: const Icon(Icons.delete, size: 18),
                label: const Text('Clear Map'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  minimumSize: const Size(double.infinity, 36),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabletControlPanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Icon(
                    _loraConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    size: 16,
                    color: _loraConnected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _loraConnected
                          ? (_connectionType == ConnectionType.usb ? 'USB' : 'BT')
                          : 'No LoRa',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: _loraConnected ? Colors.green : Colors.grey,
                      ),
                    ),
                  ),
                  if (_loraConnected && _batteryPercent != null) ...[
                    const SizedBox(width: 6),
                    Icon(
                      _getBatteryIcon(_batteryPercent!),
                      size: 14,
                      color: _getBatteryColor(_batteryPercent!),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '$_batteryPercent%',
                      style: TextStyle(
                        fontSize: 11,
                        color: _getBatteryColor(_batteryPercent!),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  Text(
                    '•',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      'Samples: $_sampleCount',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_loraConnected)
                  TextButton(
                    onPressed: _showConnectionDialog,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                    ),
                    child: const Text('Connect', style: TextStyle(fontSize: 12)),
                  ),
                if (_loraConnected)
                  IconButton(
                    icon: const Icon(Icons.send, size: 20),
                    onPressed: _manualPing,
                    tooltip: 'Manual Ping',
                    color: Colors.blue,
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  onSelected: (value) {
                    switch (value) {
                      case 'export':
                        _exportData();
                        break;
                      case 'import':
                        _importData();
                        break;
                      case 'clear':
                        _clearData();
                        break;
                      case 'disconnect':
                        _disconnectLoRa();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'export', child: Text('Export')),
                    const PopupMenuItem(value: 'import', child: Text('Import')),
                    const PopupMenuItem(value: 'clear', child: Text('Clear Map')),
                    if (_loraConnected)
                      const PopupMenuItem(
                        value: 'disconnect',
                        child: Text('Disconnect'),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _toggleAutoPing(bool? value) {
    if (value == true) {
      _locationService.enableAutoPing();
    } else {
      _locationService.disableAutoPing();
    }
    setState(() {
      _autoPingEnabled = value ?? false;
    });
  }

  Future<void> _manualPing() async {
    if (!_loraConnected) {
      _showSnackBar('Connect LoRa device first');
      return;
    }

    if (_currentPosition == null) {
      _showSnackBar('Waiting for GPS location...');
      return;
    }

    _showSnackBar('Sending ping...');

    // Send ping via LoRa companion
    final result = await _locationService.loraCompanion.ping(
      latitude: _currentPosition!.latitude,
      longitude: _currentPosition!.longitude,
    );

    // Create and save sample
    final geohash = GeohashUtils.sampleKey(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );
    
    final sample = Sample(
      id: '${DateTime.now().millisecondsSinceEpoch}_$geohash',
      position: _currentPosition!,
      timestamp: DateTime.now(),
      path: result.nodeId, // Save repeater/node ID
      geohash: geohash,
      rssi: result.rssi,
      snr: result.snr,
      pingSuccess: result.status == PingStatus.success,
    );
    
    await DatabaseService().insertSample(sample);

    // Reload samples to update map
    await _loadSamples();

    // Show result
    if (result.status == PingStatus.success) {
      _showSnackBar('✅ Ping heard by ${result.nodeId}');
    } else if (result.status == PingStatus.timeout) {
      _showSnackBar('❌ No response - dead zone');
    } else {
      _showSnackBar('❌ Ping failed: ${result.error}');
    }
  }

  void _showConnectionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect LoRa Device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose connection method:', 
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _connectUsb();
              },
              icon: const Icon(Icons.usb),
              label: const Text('Scan USB Devices'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 40),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _connectBluetooth();
              },
              icon: const Icon(Icons.bluetooth),
              label: const Text('Scan Bluetooth'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 40),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectUsb() async {
    try {
      final devices = await _locationService.loraCompanion.scanUsbDevices();
      
      if (!mounted) return;
      
      if (devices.isEmpty) {
        _showSnackBar('No USB devices found');
        return;
      }

      final selected = await showDialog<UsbDevice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select USB Device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: devices.map((device) {
              return ListTile(
                title: Text(device.productName ?? 'USB Device'),
                subtitle: Text('VID: ${device.vid}, PID: ${device.pid}'),
                onTap: () => Navigator.pop(context, device),
              );
            }).toList(),
          ),
        ),
      );

      if (selected != null) {
        final connected = await _locationService.loraCompanion.connectUsb(selected);
        if (connected) {
          _showSnackBar('Connected via USB');
          await _loadSamples();
        } else {
          _showSnackBar('Failed to connect USB device');
        }
      }
    } catch (e) {
      _showSnackBar('USB error: $e');
    }
  }

  Future<void> _connectBluetooth() async {
    try {
      _showSnackBar('Scanning for Bluetooth devices...');
      final devices = await _locationService.loraCompanion.scanBluetoothDevices();
      
      if (!mounted) return;
      
      if (devices.isEmpty) {
        _showSnackBar('No LoRa devices found via Bluetooth');
        return;
      }

      final selected = await showDialog<BluetoothDevice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select Bluetooth Device'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: devices.map((device) {
              return ListTile(
                title: Text(device.platformName),
                subtitle: Text(device.remoteId.toString()),
                onTap: () => Navigator.pop(context, device),
              );
            }).toList(),
          ),
        ),
      );

      if (selected != null) {
        _showSnackBar('Connecting to ${selected.platformName}...');
        
        final connected = await _locationService.loraCompanion.connectBluetooth(selected);
        if (connected) {
          _showSnackBar('Connected via Bluetooth!');
          await _loadSamples();
        } else {
          _showSnackBar('Failed to connect Bluetooth device');
        }
      }
    } catch (e) {
      _showSnackBar('Bluetooth error: $e');
    }
  }


  String _getPingIntervalDescription() {
    if (_pingIntervalMeters < 100) {
      return '${_pingIntervalMeters.toInt()} meters (frequent)';
    } else if (_pingIntervalMeters < 1000) {
      return '${_pingIntervalMeters.toInt()} meters';
    } else {
      final miles = (_pingIntervalMeters / 1609.34).toStringAsFixed(1);
      return '$miles miles (${_pingIntervalMeters.toInt()}m)';
    }
  }

  Future<void> _setPingInterval() async {
    String? selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ping Interval'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('How often should pings be sent?'),
            const SizedBox(height: 16),
            ListTile(
              title: const Text('Frequent'),
              subtitle: const Text('Every 50 meters'),
              onTap: () => Navigator.pop(context, '50'),
            ),
            ListTile(
              title: const Text('Normal'),
              subtitle: const Text('Every 200 meters (~0.12 miles)'),
              onTap: () => Navigator.pop(context, '200'),
            ),
            ListTile(
              title: const Text('Sparse'),
              subtitle: const Text('Every 0.5 miles (805 meters)'),
              onTap: () => Navigator.pop(context, '805'),
            ),
            ListTile(
              title: const Text('Very Sparse'),
              subtitle: const Text('Every 1 mile (1609 meters)'),
              onTap: () => Navigator.pop(context, '1609'),
            ),
          ],
        ),
      ),
    );

    if (selected != null) {
      final interval = double.parse(selected);
      setState(() {
        _pingIntervalMeters = interval;
      });
      // Update location service ping interval
      _locationService.setPingInterval(_pingIntervalMeters);
      await _settingsService.setPingInterval(interval);
      _showSnackBar('Ping interval: ${_getPingIntervalDescription()}');
    }
  }

  String _getCoverageResolutionDescription() {
    switch (_coveragePrecision) {
      case 4:
        return 'Regional (~20km squares)';
      case 5:
        return 'City-level (~5km squares)';
      case 6:
        return 'Neighborhood (~1.2km squares)';
      case 7:
        return 'Street-level (~153m squares)';
      case 8:
        return 'Building-level (~38m squares)';
      default:
        return 'Unknown';
    }
  }

  Future<void> _setCoverageResolution() async {
    String? selected = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Coverage Resolution'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Choose the size of coverage squares:'),
            const SizedBox(height: 16),
            ListTile(
              title: const Text('Regional'),
              subtitle: const Text('~20km squares (precision 4)'),
              onTap: () => Navigator.pop(context, '4'),
            ),
            ListTile(
              title: const Text('City-level'),
              subtitle: const Text('~5km squares (precision 5)'),
              onTap: () => Navigator.pop(context, '5'),
            ),
            ListTile(
              title: const Text('Neighborhood'),
              subtitle: const Text('~1.2km squares (precision 6, default)'),
              onTap: () => Navigator.pop(context, '6'),
            ),
            ListTile(
              title: const Text('Street-level'),
              subtitle: const Text('~153m squares (precision 7)'),
              onTap: () => Navigator.pop(context, '7'),
            ),
            ListTile(
              title: const Text('Building-level'),
              subtitle: const Text('~38m squares (precision 8, detailed)'),
              onTap: () => Navigator.pop(context, '8'),
            ),
          ],
        ),
      ),
    );

    if (selected != null) {
      final precision = int.parse(selected);
      setState(() {
        _coveragePrecision = precision;
      });
      await _settingsService.setCoveragePrecision(precision);
      // Reload samples with new precision
      await _loadSamples();
      _showSnackBar('Coverage resolution: ${_getCoverageResolutionDescription()}');
    }
  }

  Future<void> _setIgnoredRepeater() async {
    final controller = TextEditingController(text: _ignoredRepeaterPrefix ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ignore Mobile Repeater'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Filter out responses from your mobile repeater to avoid false coverage.\n\n'
              'Enter the first 2-3 characters of your repeater\'s public key:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Public Key Prefix',
                hintText: 'e.g., 7E, A4F, etc.',
                isDense: true,
              ),
              textCapitalization: TextCapitalization.characters,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final prefix = controller.text.isEmpty ? null : controller.text;
      setState(() {
        _ignoredRepeaterPrefix = prefix;
      });
      _locationService.loraCompanion.setIgnoredRepeaterPrefix(_ignoredRepeaterPrefix);
      await _settingsService.setIgnoredRepeaterPrefix(prefix);
      _showSnackBar('Repeater prefix updated');
    }
  }

  Future<void> _setIncludeOnlyRepeaters() async {
    final controller = TextEditingController(text: _includeOnlyRepeaters ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Include Only Repeaters'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Show ONLY samples from specific repeaters (whitelist). Useful for testing your own infrastructure.\n\n'
              'Enter repeater prefixes separated by commas:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Repeater Prefixes',
                hintText: 'e.g., 7E3A, A4F2, 8B',
                isDense: true,
              ),
              textCapitalization: TextCapitalization.characters,
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final prefixes = controller.text.isEmpty ? null : controller.text;
      setState(() {
        _includeOnlyRepeaters = prefixes;
      });
      await _settingsService.setIncludeOnlyRepeaters(prefixes);
      _showSnackBar('Repeater whitelist updated');
    }
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              controller: scrollController,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            Row(
              children: [
                const Text(
                  'Settings',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Text(
                  'v$appVersion',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Show Coverage Boxes'),
              value: _showCoverage,
              onChanged: (value) async {
                setState(() {
                  _showCoverage = value;
                });
                await _settingsService.setShowCoverage(value);
                Navigator.pop(context);
              },
            ),
            SwitchListTile(
              title: const Text('Show Samples'),
              value: _showSamples,
              onChanged: (value) async {
                setState(() {
                  _showSamples = value;
                });
                await _settingsService.setShowSamples(value);
                Navigator.pop(context);
              },
            ),
            SwitchListTile(
              title: const Text('Show Edges'),
              value: _showEdges,
              onChanged: (value) async {
                setState(() {
                  _showEdges = value;
                });
                await _settingsService.setShowEdges(value);
                Navigator.pop(context);
              },
            ),
            SwitchListTile(
              title: const Text('Show Repeaters'),
              value: _showRepeaters,
              onChanged: (value) async {
                setState(() {
                  _showRepeaters = value;
                });
                await _settingsService.setShowRepeaters(value);
                Navigator.pop(context);
              },
            ),
            SwitchListTile(
              title: const Text('Show GPS Samples'),
              subtitle: const Text('Show blue GPS-only markers'),
              value: _showGpsSamples,
              onChanged: (value) async {
                setState(() {
                  _showGpsSamples = value;
                });
                await _settingsService.setShowGpsSamples(value);
                Navigator.pop(context);
              },
            ),
            SwitchListTile(
              title: const Text('Show Successful Pings Only'),
              subtitle: const Text('Hide failed pings and GPS-only samples'),
              value: _showSuccessfulOnly,
              onChanged: (value) async {
                setState(() {
                  _showSuccessfulOnly = value;
                });
                Navigator.pop(context);
                _showSnackBar(value ? 'Showing successful only' : 'Showing all samples');
              },
            ),
            SwitchListTile(
              title: const Text('Lock Rotation to North'),
              subtitle: const Text('Prevent map rotation'),
              value: _lockRotationNorth,
              onChanged: (value) async {
                setState(() {
                  _lockRotationNorth = value;
                });
                Navigator.pop(context);
                _showSnackBar(value ? 'Rotation locked' : 'Rotation unlocked');
              },
            ),
            ListTile(
              title: const Text('Theme'),
              subtitle: Text(_getThemeModeText()),
              trailing: const Icon(Icons.brightness_6),
              onTap: () {
                Navigator.pop(context);
                _showThemeSelector();
              },
            ),
            if (_loraConnected)
              ListTile(
                title: const Text('Scan for Repeaters'),
                subtitle: Text(_repeaters.isEmpty 
                    ? 'Find nearby LoRa nodes' 
                    : '${_repeaters.length} repeater(s) found'),
                leading: const Icon(Icons.cell_tower),
                trailing: const Icon(Icons.search),
                onTap: () {
                  Navigator.pop(context);
                  _scanForRepeaters();
                },
              ),
            if (_loraConnected)
              ListTile(
                title: const Text('Refresh Contact List'),
                subtitle: const Text('Update repeater names from device'),
                leading: const Icon(Icons.refresh),
                onTap: () {
                  Navigator.pop(context);
                  _refreshContacts();
                },
              ),
            ListTile(
              title: const Text('Color Mode'),
              trailing: DropdownButton<String>(
                value: _colorMode,
                items: const [
                  DropdownMenuItem(value: 'quality', child: Text('Quality')),
                  DropdownMenuItem(value: 'age', child: Text('Age')),
                ],
                onChanged: (value) async {
                  setState(() {
                    _colorMode = value!;
                  });
                  await _settingsService.setColorMode(value!);
                  Navigator.pop(context);
                },
              ),
            ),
            ListTile(
              title: const Text('Ignore Mobile Repeater'),
              subtitle: Text(_ignoredRepeaterPrefix != null 
                  ? 'Filtering: ${_ignoredRepeaterPrefix}*' 
                  : 'Not filtering'),
              trailing: const Icon(Icons.edit),
              onTap: () {
                Navigator.pop(context);
                _setIgnoredRepeater();
              },
            ),
            ListTile(
              title: const Text('Include Only Repeaters'),
              subtitle: Text(_includeOnlyRepeaters != null && _includeOnlyRepeaters!.isNotEmpty
                  ? 'Whitelist: ${_includeOnlyRepeaters}' 
                  : 'Show all repeaters'),
              trailing: const Icon(Icons.edit),
              onTap: () {
                Navigator.pop(context);
                _setIncludeOnlyRepeaters();
              },
            ),
            ListTile(
              title: const Text('Ping Interval'),
              subtitle: Text(_getPingIntervalDescription()),
              trailing: const Icon(Icons.tune),
              onTap: () {
                Navigator.pop(context);
                _setPingInterval();
              },
            ),
            ListTile(
              title: const Text('Coverage Resolution'),
              subtitle: Text(_getCoverageResolutionDescription()),
              trailing: const Icon(Icons.grid_on),
              onTap: () {
                Navigator.pop(context);
                _setCoverageResolution();
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Debug',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ListTile(
              title: const Text('Debug Diagnostics'),
              subtitle: const Text('View debug logs for troubleshooting'),
              leading: const Icon(Icons.bug_report),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _openDebugDiagnostics();
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Online Map',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ListTile(
              title: const Text('Upload Data'),
              subtitle: const Text('Upload samples to web map'),
              leading: const Icon(Icons.cloud_upload),
              onTap: () {
                Navigator.pop(context);
                _uploadSamples();
              },
            ),
            ListTile(
              title: const Text('Configure API'),
              subtitle: const Text('Set upload URL'),
              leading: const Icon(Icons.settings),
              onTap: () {
                Navigator.pop(context);
                _configureUploadUrl();
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'About',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            ListTile(
              title: const Text('Check for Updates'),
              subtitle: const Text('Current version: v$appVersion'),
              leading: const Icon(Icons.system_update),
              trailing: const Icon(Icons.arrow_forward),
              onTap: () {
                Navigator.pop(context);
                _checkForUpdates();
              },
            ),
            ListTile(
              title: const Text('View on GitHub'),
              subtitle: const Text('Source code and releases'),
              leading: const Icon(Icons.code),
              trailing: const Icon(Icons.open_in_new),
              onTap: () {
                Navigator.pop(context);
                _openGitHub();
              },
            ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  
  
  Future<void> _disconnectLoRa() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect LoRa Device'),
        content: const Text('Disconnect from your LoRa companion device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      // Disable auto-ping first
      if (_autoPingEnabled) {
        _locationService.disableAutoPing();
      }
      
      await _locationService.loraCompanion.disconnectDevice();
      await _loadSamples();
      _showSnackBar('LoRa device disconnected');
    }
  }
  
  
  IconData _getBatteryIcon(int percent) {
    if (percent > 90) return Icons.battery_full;
    if (percent > 70) return Icons.battery_5_bar;
    if (percent > 50) return Icons.battery_4_bar;
    if (percent > 30) return Icons.battery_3_bar;
    if (percent > 15) return Icons.battery_2_bar;
    return Icons.battery_1_bar;
  }
  
  Color _getBatteryColor(int percent) {
    if (percent > 30) return Colors.green;
    if (percent > 15) return Colors.orange;
    return Colors.red;
  }
  
  Future<void> _refreshContacts() async {
    if (!_loraConnected) {
      _showSnackBar('Connect LoRa device first');
      return;
    }
    
    _showSnackBar('Refreshing contact list...');
    
    // Request full contact list from device
    await _locationService.loraCompanion.refreshContactList();
    
    // Give it a moment to process
    await Future.delayed(const Duration(seconds: 2));
    
    _showSnackBar('Contact list updated');
  }
  
  Future<void> _scanForRepeaters() async {
    if (!_loraConnected) {
      _showSnackBar('Connect LoRa device first');
      return;
    }
    
    _showSnackBar('Scanning for repeaters...');
    
    final repeaters = await _locationService.loraCompanion.scanForRepeaters();
    
    setState(() {
      _repeaters = repeaters;
    });
    
    if (repeaters.isEmpty) {
      _showSnackBar('No repeaters found');
    } else {
      _showSnackBar('Found ${repeaters.length} repeater(s)');
      _showRepeatersDialog();
    }
  }
  
  void _openDebugDiagnostics() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DebugDiagnosticsScreen(
          locationService: _locationService,
        ),
      ),
    );
  }
  
  String _getThemeModeText() {
    final appState = MyApp.of(context);
    if (appState == null) return 'System Default';
    
    switch (appState.themeMode) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'System Default';
    }
  }
  
  Future<void> _showThemeSelector() async {
    final appState = MyApp.of(context);
    if (appState == null) return;
    
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose Theme'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Light'),
              leading: const Icon(Icons.light_mode),
              onTap: () => Navigator.pop(context, ThemeMode.light),
            ),
            ListTile(
              title: const Text('Dark'),
              leading: const Icon(Icons.dark_mode),
              onTap: () => Navigator.pop(context, ThemeMode.dark),
            ),
            ListTile(
              title: const Text('System Default'),
              leading: const Icon(Icons.brightness_auto),
              onTap: () => Navigator.pop(context, ThemeMode.system),
            ),
          ],
        ),
      ),
    );
    
    if (selected != null) {
      await appState.setThemeMode(selected);
      setState(() {}); // Refresh to update map tiles
    }
  }
  
  String? _getRepeaterName(String? repeaterId) {
    if (repeaterId == null) return null;
    
    // If it's a 2-char prefix, try to expand it first
    String? fullId = repeaterId;
    if (repeaterId.length == 2) {
      fullId = _locationService.loraCompanion.matchRepeaterPrefix(repeaterId);
      if (fullId == null) {
        // No match found, return the 2-char prefix as-is
        return repeaterId;
      }
    }
    
    // First check discovered repeaters list
    final repeater = _repeaters.firstWhere(
      (r) => r.id == fullId,
      orElse: () => Repeater(id: fullId!, position: const LatLng(0, 0), timestamp: DateTime.now()),
    );
    if (repeater.name != null) return repeater.name;
    
    // Fall back to checking LoRa service's contact cache
    final loraRepeater = _locationService.loraCompanion.getRepeaterLocation(fullId!);
    return loraRepeater?.name ?? fullId; // Return full ID if no name
  }
  
  void _showSampleInfo(Sample sample) {
    final timestamp = DateFormat('MMM d, yyyy HH:mm:ss').format(sample.timestamp);
    final hasSignalData = sample.rssi != null || sample.snr != null;
    final pingStatus = sample.pingSuccess == true 
        ? '✅ Success' 
        : sample.pingSuccess == false 
            ? '❌ Failed' 
            : '📍 GPS Only';
    
    // Get repeater name if available (sample.path holds repeater/node ID)
    final repeaterName = sample.path != null ? _getRepeaterName(sample.path) : null;
    final idOrName = repeaterName ?? sample.path ?? 'Unknown';
    final repeaterDisplay = (repeaterName != null)
        ? repeaterName
        : (idOrName.length > 8 ? idOrName.substring(0, 8).toUpperCase() : idOrName.toUpperCase());
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sample Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Status: ', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(pingStatus),
              ],
            ),
            const SizedBox(height: 8),
            Text('Time: $timestamp', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Text('Lat: ${sample.position.latitude.toStringAsFixed(6)}'),
            Text('Lon: ${sample.position.longitude.toStringAsFixed(6)}'),
            if (sample.path != null) ...[
              const Divider(height: 16),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Repeater: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(child: Text(repeaterDisplay, style: const TextStyle(fontFamily: 'monospace'))),
                ],
              ),
            ],
            if (hasSignalData)
              const Divider(height: 16),
            if (hasSignalData)
              const SizedBox(height: 8),
            if (sample.rssi != null)
              Row(
                children: [
                  const Text('RSSI: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${sample.rssi} dBm'),
                ],
              ),
            if (sample.snr != null)
              Row(
                children: [
                  const Text('SNR: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${sample.snr} dB'),
                ],
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
  
  void _showRepeaterInfo(Repeater repeater) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(repeater.name ?? 'Repeater ${(repeater.id.length > 8 ? repeater.id.substring(0,8) : repeater.id).toUpperCase()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ID: ${(repeater.id.length > 8 ? repeater.id.substring(0,8) : repeater.id).toUpperCase()}', style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Text('Lat: ${repeater.position.latitude.toStringAsFixed(6)}'),
            Text('Lon: ${repeater.position.longitude.toStringAsFixed(6)}'),
            if (repeater.rssi != null)
              const SizedBox(height: 8),
            if (repeater.rssi != null)
              Text('RSSI: ${repeater.rssi} dBm'),
            if (repeater.snr != null)
              Text('SNR: ${repeater.snr} dB'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _mapController.move(repeater.position, 15.0);
            },
            child: const Text('Show on Map'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
  
  void _showCoverageInfo(Coverage coverage) {
    // Calculate total samples and success rate
    final total = coverage.received + coverage.lost;
    final successRate = total > 0 ? ((coverage.received / total) * 100).toStringAsFixed(0) : 'N/A';
    final reliabilityText = total > 0 ? '$successRate%' : 'No ping data';
    
    // Round weighted values to 1 decimal place for display
    final receivedDisplay = coverage.received.toStringAsFixed(1);
    final lostDisplay = coverage.lost.toStringAsFixed(1);
    final totalDisplay = total.toStringAsFixed(1);
    
    // Get unique repeater prefixes (first 2 chars)
    final uniquePrefixes = coverage.repeaters.map((id) => id.substring(0, id.length >= 2 ? 2 : id.length)).toSet().toList()..sort();
    final repeaterText = uniquePrefixes.isNotEmpty ? uniquePrefixes.join(', ') : 'None';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Coverage Square Info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Samples: ', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(totalDisplay),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Success Rate: ', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(reliabilityText),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Received: ', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                Flexible(child: Text(receivedDisplay)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Lost: ', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                Flexible(child: Text(lostDisplay)),
              ],
            ),
            if (coverage.received > 0)
              const SizedBox(height: 8),
            if (coverage.received > 0)
              Row(
                children: [
                  const Text('Repeaters Heard: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('${uniquePrefixes.length}'),
                ],
              ),
            if (coverage.received > 0)
              const SizedBox(height: 4),
            if (coverage.received > 0)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Repeater IDs: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  Expanded(
                    child: Text(
                      repeaterText,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showRepeatersDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Nearby Repeaters (${_repeaters.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _repeaters.length,
            itemBuilder: (context, index) {
              final repeater = _repeaters[index];
              return ListTile(
                leading: const Icon(Icons.cell_tower, color: Colors.purple),
                title: Text(repeater.name ?? 'Repeater ${repeater.id}'),
                subtitle: Text(
                  '${repeater.position.latitude.toStringAsFixed(4)}, '
                  '${repeater.position.longitude.toStringAsFixed(4)}'
                  '${repeater.snr != null ? " • SNR: ${repeater.snr} dB" : ""}'
                  '${repeater.rssi != null ? " • RSSI: ${repeater.rssi} dBm" : ""}',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showRepeaterInfo(repeater);
                },
                trailing: IconButton(
                  icon: const Icon(Icons.location_searching),
                  onPressed: () {
                    Navigator.pop(context);
                    _mapController.move(repeater.position, 15.0);
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadSamples() async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Uploading samples...'),
          ],
        ),
      ),
    );

    try {
      // Build repeater names map from discovered repeaters and LoRa service
      final repeaterNames = <String, String>{};
      
      // Add names from discovered repeaters
      for (final repeater in _repeaters) {
        if (repeater.name != null) {
          repeaterNames[repeater.id] = repeater.name!;
        }
      }
      
      // Add names from LoRa service contact cache
      final loraService = _locationService.loraCompanion;
      for (final contact in loraService.discoveredRepeaters) {
        if (contact.name != null && !repeaterNames.containsKey(contact.id)) {
          repeaterNames[contact.id] = contact.name!;
        }
      }
      
      final result = await _uploadService.uploadAllSamples(repeaterNames: repeaterNames);
      
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(result.success ? 'Upload Complete' : 'Upload Failed'),
            content: Text(result.success ? 'Upload Complete' : result.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        _showSnackBar('Upload error: $e');
      }
    }
  }

  Future<void> _configureUploadUrl() async {
    final currentUrl = await _uploadService.getApiUrl();
    final controller = TextEditingController(text: currentUrl);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Configure Upload URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the URL of your Cloudflare Pages API endpoint:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'API URL',
                hintText: 'https://your-site.pages.dev/api/samples',
                isDense: true,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                controller.text = UploadService.defaultApiUrl;
              },
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('Reset to default', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _uploadService.setApiUrl(controller.text);
      _showSnackBar('Upload URL saved');
    }
  }
  
}
