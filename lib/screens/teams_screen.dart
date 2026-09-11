import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import 'app_menu.dart';

class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key});

  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  final _supabase = SupabaseService.client;
  bool _isLoading = true;
  List<Map<String, dynamic>> _teams = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final teams = await SupabaseService.loadTeamsSafe();
    setState(() {
      _teams = teams;
      _isLoading = false;
    });
  }

  Future<void> _showCreateTeamDialog() async {
    final nameController = TextEditingController();
    String? validationError;
    bool isSaving = false;
    bool dialogOpen = true;

    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> createTeam() async {
            final name = nameController.text.trim();
            if (name.isEmpty) {
              setDialogState(() => validationError = 'Zadejte název týmu.');
              return;
            }

            setDialogState(() {
              validationError = null;
              isSaving = true;
            });

            try {
              final userId = _supabase.auth.currentUser?.id;
              if (userId == null) {
                throw Exception('Uživatel není přihlášen.');
              }
              final inserted = await _supabase.from('teams').insert({
                'name': name,
                'km': 0.0,
                'originator_id': userId,
              }).select('id, name, km, originator_id').single();
              if (dialogOpen && dialogContext.mounted) {
                FocusManager.instance.primaryFocus?.unfocus();
                Navigator.of(dialogContext).pop(Map<String, dynamic>.from(inserted));
              }
            } catch (e) {
              if (dialogOpen) {
                setDialogState(() {
                  validationError = formatBackendError(e, context: 'Vytvoření týmu selhalo');
                  isSaving = false;
                });
              }
            }
          }

          return AlertDialog(
            title: const Text('Přidat nový tým'),
            content: TextField(
              controller: nameController,
              enabled: !isSaving,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Název týmu',
                errorText: validationError,
              ),
              onSubmitted: isSaving ? null : (_) => createTeam(),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  dialogOpen = false;
                  FocusManager.instance.primaryFocus?.unfocus();
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Zrušit'),
              ),
              FilledButton(
                onPressed: isSaving ? null : createTeam,
                child: isSaving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Přidat'),
              ),
            ],
          );
        },
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 250));
    nameController.dispose();
    if (created != null && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _teams = [..._teams, created]);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tým byl přidán.'), backgroundColor: Colors.green),
        );
      });
    }
  }

  Future<void> _showTeamMembers(Map<String, dynamic> team) async {
    final teamId = team['id'];
    if (teamId == null) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(team['name'].toString()),
          content: SizedBox(
            width: double.maxFinite,
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _loadTeamMembers(team),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 80,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Text(formatBackendError(snapshot.error!, context: 'Načtení členů týmu selhalo'));
                }
                final members = snapshot.data ?? const <Map<String, dynamic>>[];
                if (members.isEmpty) {
                  return const Text('Tým zatím nemá žádné členy.');
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: members.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final member = members[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _buildMemberAvatar(member['avatar_base64']?.toString()),
                        title: Text((member['runner_name'] ?? 'Neznámý člen').toString()),
                      );
                    },
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Zavřít'),
            ),
          ],
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _loadTeamMembers(Map<String, dynamic> team) async {
    final teamId = team['id'];
    final rows = await _supabase
        .from('profiles')
        .select('user_id, runner_name, team_id, team_name, avatar_base64')
        .eq('team_id', teamId)
        .order('runner_name');
    final members = List<Map<String, dynamic>>.from(rows);

    try {
      final profile = await SupabaseService.loadCurrentProfile();
      final profileTeamId = profile['team_id']?.toString();
      final profileTeamName = (profile['team_name'] ?? '').toString().trim().toLowerCase();
      final currentTeamName = (team['name'] ?? '').toString().trim().toLowerCase();
      final belongsToTeam = profileTeamId == teamId.toString() ||
          (profileTeamId == null && profileTeamName.isNotEmpty && profileTeamName == currentTeamName);
      final userId = profile['user_id']?.toString();
      final runnerName = (profile['runner_name'] ?? '').toString().trim();

      if (belongsToTeam && runnerName.isNotEmpty) {
        final alreadyListed = members.any((member) {
          final listedUserId = member['user_id']?.toString();
          final listedRunnerName = (member['runner_name'] ?? '').toString().trim().toLowerCase();
          return (userId != null && listedUserId == userId) || listedRunnerName == runnerName.toLowerCase();
        });
        if (!alreadyListed) {
          members.add({
            'user_id': userId,
            'runner_name': runnerName,
            'avatar_base64': profile['avatar_base64'],
          });
        }
      }
    } catch (e) {
      debugPrint('Current profile could not be added to team members: $e');
    }

    members.sort((left, right) =>
        (left['runner_name'] ?? '').toString().toLowerCase().compareTo(
              (right['runner_name'] ?? '').toString().toLowerCase(),
            ));
    return members;
  }

  Widget _buildMemberAvatar(String? avatarBase64) {
    final value = avatarBase64?.trim() ?? '';
    if (value.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.person));
    }
    try {
      return CircleAvatar(
        backgroundImage: MemoryImage(base64Decode(value)),
      );
    } catch (_) {
      return const CircleAvatar(child: Icon(Icons.person));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Týmy'),
        backgroundColor: Colors.orange,
        leading: buildBackToDashboardButton(context),
        actions: [buildAppMenu(context)],
      ),
      body: _isLoading ? const Center(child: CircularProgressIndicator()) : Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(children: [
          Expanded(child: ListView.builder(
            itemCount: _teams.length,
            itemBuilder: (context, i) {
              final t = _teams[i];
              return Card(
                child: ListTile(
                  title: Text(t['name']),
                  subtitle: Text('${t['km']} km'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showTeamMembers(t),
                ),
              );
            },
          )),
        ]),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Přidat tým',
        onPressed: _showCreateTeamDialog,
        backgroundColor: Colors.orange,
        child: const Icon(Icons.add),
      ),
    );
  }
}

