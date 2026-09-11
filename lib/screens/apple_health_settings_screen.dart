import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/supabase_service.dart';
import 'app_menu.dart';

class AppleHealthSettingsScreen extends StatefulWidget {
  const AppleHealthSettingsScreen({super.key});

  @override
  State<AppleHealthSettingsScreen> createState() => _AppleHealthSettingsScreenState();
}

class _AppleHealthSettingsScreenState extends State<AppleHealthSettingsScreen> {
  bool _isCreatingHealthToken = false;
  String? _healthShortcutToken;

  Future<void> _createHealthShortcutToken() async {
    setState(() => _isCreatingHealthToken = true);
    try {
      final token = await SupabaseService.createHealthShortcutToken();
      if (!mounted) return;
      setState(() => _healthShortcutToken = token);
      await Clipboard.setData(ClipboardData(text: token));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Token vytvořen a zkopírován do schránky.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Token se nepodařilo vytvořit: $e')),
      );
    } finally {
      if (mounted) setState(() => _isCreatingHealthToken = false);
    }
  }

  Future<void> _copyToken() async {
    final token = _healthShortcutToken;
    if (token == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: token));
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Token zkopírován.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nastavení'),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
        leading: buildBackToDashboardButton(context),
        actions: [buildAppMenu(context)],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Apple Health přes Zkratky', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('Vytvořte token, vložte ho do sdílené iPhone Zkratky a povolte jí přístup ke Zdraví.'),
                const SizedBox(height: 12),
                if (_healthShortcutToken != null) ...[
                  SelectableText(_healthShortcutToken!, style: const TextStyle(fontFamily: 'monospace')),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _copyToken,
                    icon: const Icon(Icons.copy),
                    label: const Text('Kopírovat token'),
                  ),
                ],
                FilledButton.icon(
                  onPressed: _isCreatingHealthToken ? null : _createHealthShortcutToken,
                  icon: _isCreatingHealthToken
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.key),
                  label: Text(_healthShortcutToken == null ? 'Vytvořit token' : 'Vytvořit nový token'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}