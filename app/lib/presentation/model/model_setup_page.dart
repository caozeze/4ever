import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../application/ai/demo_chat_controller.dart';
import '../../application/ai/model/model_connection_controller.dart';
import '../../core/providers/model_management_providers.dart';
import '../../domain/ai/device_capabilities.dart';
import '../../domain/ai/model_install_status.dart';
import '../../domain/ai/model_manifest_entry.dart';
import '../app_navigation_drawer.dart';

class ModelSetupPage extends ConsumerStatefulWidget {
  const ModelSetupPage({super.key});

  static const String path = '/models';

  @override
  ConsumerState<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends ConsumerState<ModelSetupPage> {
  late Future<_ModelSetupData> _dataFuture;
  String? _selectedModelId;

  @override
  void initState() {
    super.initState();
    _dataFuture = _loadData();
  }

  Future<_ModelSetupData> _loadData() async {
    final manifest = await ref.read(modelCatalogProvider).load();
    final capabilities = await ref
        .read(deviceCapabilitiesReaderProvider)
        .read();
    final models =
        manifest.models
            .where((model) => model.runtime == 'coreml_llm')
            .where((model) => model.supportsPlatform(capabilities.platform))
            .toList()
          ..sort((a, b) => a.selectionPriority.compareTo(b.selectionPriority));
    _selectedModelId ??=
        ref.read(modelConnectionControllerProvider).preferredModelId ??
        DemoChatController.defaultPreferredModelId;
    return _ModelSetupData(models: models, capabilities: capabilities);
  }

  Future<void> _prepareSelectedModel() async {
    final selectedModelId = _selectedModelId;
    if (selectedModelId == null) {
      return;
    }
    await ref
        .read(modelConnectionControllerProvider)
        .ensureModelReady(preferredModelId: selectedModelId, force: true);
    if (!mounted) {
      return;
    }
    if (ref.read(modelConnectionControllerProvider).snapshot.isReady) {
      context.go('/chat');
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(modelConnectionControllerProvider).snapshot;
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      drawer: const AppNavigationDrawer(currentPath: ModelSetupPage.path),
      body: SafeArea(
        child: FutureBuilder<_ModelSetupData>(
          future: _dataFuture,
          builder: (BuildContext context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!;
            final selectedModel = data.models
                .where((model) => model.id == _selectedModelId)
                .firstOrNull;
            final canPrepare =
                selectedModel != null &&
                data.isCompatible(selectedModel) &&
                !connection.isConnecting;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(
                  'Choose Local Gemma',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'Download one model before chat. You can return here later to switch between E2B and E4B.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                for (final model in data.models) ...<Widget>[
                  _ModelOptionTile(
                    model: model,
                    capabilities: data.capabilities,
                    selected: model.id == _selectedModelId,
                    connection: connection.modelId == model.id
                        ? connection
                        : null,
                    onSelected: () {
                      setState(() {
                        _selectedModelId = model.id;
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey<String>('model_prepare_button'),
                  onPressed: canPrepare ? _prepareSelectedModel : null,
                  icon: connection.isConnecting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_primaryActionLabel(connection)),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey<String>('model_open_chat_button'),
                  onPressed: connection.isReady
                      ? () => context.go('/chat')
                      : null,
                  icon: const Icon(Icons.chat_bubble),
                  label: const Text('Open Chat'),
                ),
                if (connection.isFailed && connection.message != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          connection.message!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const ValueKey<String>('gemma_retry_button'),
                        onPressed: () =>
                            ref.read(modelConnectionControllerProvider).retry(),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  String _primaryActionLabel(ModelConnectionSnapshot connection) {
    if (connection.isConnecting) {
      return connection.message ?? 'Preparing...';
    }
    if (connection.isReady) {
      return 'Switch / Load Selected Model';
    }
    return 'Download and Load';
  }
}

class _ModelOptionTile extends StatelessWidget {
  const _ModelOptionTile({
    required this.model,
    required this.capabilities,
    required this.selected,
    required this.connection,
    required this.onSelected,
  });

  final ModelManifestEntry model;
  final DeviceCapabilities capabilities;
  final bool selected;
  final ModelConnectionSnapshot? connection;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final compatible =
        capabilities.totalMemoryGb >= model.minMemoryGb &&
        capabilities.freeDiskBytes >= model.minFreeDiskBytes;
    final connection = this.connection;
    final statusText = connection == null
        ? _compatibilityText(compatible)
        : _statusText(connection.status);
    return Card(
      child: ListTile(
        onTap: compatible ? onSelected : null,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(model.displayName),
        subtitle: Text(
          '${_sizeLabel(model.sizeBytes)} required, ${model.minMemoryGb}GB memory minimum\n$statusText',
        ),
        trailing: Icon(
          model.id.contains('e4b') ? Icons.memory : Icons.bolt,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        selected: selected,
      ),
    );
  }

  String _compatibilityText(bool compatible) {
    if (compatible) {
      return 'Available for this device';
    }
    return 'Not enough memory or free disk for this device';
  }

  String _statusText(ModelInstallStatus status) {
    return switch (status) {
      ModelInstallStatus.notInstalled => 'Checking',
      ModelInstallStatus.downloading => 'Downloading',
      ModelInstallStatus.verifying => 'Verifying',
      ModelInstallStatus.installed => 'Installed',
      ModelInstallStatus.loading => 'Loading',
      ModelInstallStatus.ready => 'Ready',
      ModelInstallStatus.failed => 'Failed',
      ModelInstallStatus.unloaded => 'Unloaded',
    };
  }

  String _sizeLabel(int bytes) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }
}

class _ModelSetupData {
  const _ModelSetupData({required this.models, required this.capabilities});

  final List<ModelManifestEntry> models;
  final DeviceCapabilities capabilities;

  bool isCompatible(ModelManifestEntry model) {
    return capabilities.totalMemoryGb >= model.minMemoryGb &&
        capabilities.freeDiskBytes >= model.minFreeDiskBytes;
  }
}
