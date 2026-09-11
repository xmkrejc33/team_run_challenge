import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import 'app_menu.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _supabase = Supabase.instance.client;
  final _imagePicker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  String? _avatarBase64;
  bool _isLoading = true;
  bool _isSavingProfile = false;
  List<Map<String, dynamic>> _availableTeams = [];
  List<Map<String, dynamic>> _userActivities = [];
  int? _selectedTeamId;
  int? _initialTeamId;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final user = _supabase.auth.currentUser;
    Map<String, dynamic>? profile;
    String? runnerName;
    if (user != null) {
      profile = await SupabaseService.loadCurrentProfile();
      runnerName = (profile['runner_name'] ?? '').toString().trim();
      _nameController.text = runnerName;
      _avatarBase64 = profile['avatar_base64']?.toString();
      _selectedTeamId = profile['team_id'] is int ? profile['team_id'] : int.tryParse(profile['team_id']?.toString() ?? '');
      _initialTeamId = _selectedTeamId;
    }

    final teams = await SupabaseService.loadTeamsSafe();
    final activities = await SupabaseService.loadActivitiesSafe(
      runnerName: runnerName,
      ascending: false,
    );

    if (!mounted) return;
    setState(() {
      _availableTeams = teams;
      _userActivities = activities;
      _isLoading = false;
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _isSavingProfile = true);
    try {
      final selectedTeam = _availableTeams.firstWhere((t) => t['id'] == _selectedTeamId);
      await SupabaseService.saveCurrentProfile(
        runnerName: _nameController.text.trim(),
        teamId: _selectedTeamId,
        teamName: selectedTeam['name'].toString(),
        avatarBase64: _avatarBase64,
      );
      if (_selectedTeamId != _initialTeamId) _initialTeamId = _selectedTeamId;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profil uložen.')));
      }
    } catch (e) { debugPrint(e.toString()); }
    setState(() => _isSavingProfile = false);
  }

  Future<void> _pickProfileImage() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 800,
        maxHeight: 800,
      );
      if (image == null) return;

      final imageBytes = await image.readAsBytes();
      if (!mounted) return;
      setState(() => _avatarBase64 = base64Encode(imageBytes));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fotografii se nepodařilo načíst: $e')),
      );
    }
  }

  ImageProvider<Object>? _profileImage() {
    final avatar = _avatarBase64?.trim();
    if (avatar == null || avatar.isEmpty) return null;
    try {
      return MemoryImage(base64Decode(avatar));
    } on FormatException {
      debugPrint('Profilový obrázek má neplatný base64 formát.');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        leading: buildBackToDashboardButton(context),
        actions: [buildAppMenu(context)],
      ),
      body: _isLoading ? const Center(child: CircularProgressIndicator()) : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          GestureDetector(
            onTap: _pickProfileImage,
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                CircleAvatar(
                  radius: 46,
                  backgroundImage: _profileImage(),
                  child: _profileImage() == null ? const Icon(Icons.person, size: 46) : null,
                ),
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.orange,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(7),
                  child: const Icon(Icons.edit, color: Colors.white, size: 18),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Jméno', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _selectedTeamId,
            items: _availableTeams.map((t) => DropdownMenuItem<int>(value: t['id'] as int, child: Text(t['name']))).toList(),
            onChanged: (v) => setState(() => _selectedTeamId = v),
            decoration: const InputDecoration(labelText: 'Tým', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isSavingProfile ? null : _saveProfile,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Uložit změny'),
          ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Moje aktivity',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          if (_userActivities.isEmpty)
            const Text('Zatím nemáte žádné aktivity.')
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _userActivities.length,
              itemBuilder: (context, index) {
                final activity = _userActivities[index];
                final teamName = (activity['team_name'] ?? 'Neznámý tým').toString();
                final km = (activity['km'] as num?)?.toDouble() ?? 0.0;
                final startTime = activity['start_time'] ?? activity['created_at'] ?? '';
                final formattedDate = _formatActivityDate(startTime.toString());

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundImage: _profileImage(),
                      child: _profileImage() == null ? const Icon(Icons.person) : null,
                    ),
                    title: Text(teamName),
                    subtitle: Text(formattedDate),
                    trailing: Text(
                      '${km.toStringAsFixed(1)} km',
                      style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange),
                    ),
                  ),
                );
              },
            ),
        ]),
      ),
    );
  }

  String _formatActivityDate(String rawValue) {
    final parsed = DateTime.tryParse(rawValue);
    if (parsed == null) return 'Neznámé datum';
    return '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }

}

