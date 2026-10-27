import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'pro.dart';

/// Aggiornamenti dentro l'app (solo se installata dal Play Store).
/// - versione sotto la minima del pannello admin → aggiornamento obbligatorio
/// - altrimenti, se c'è una versione nuova → scarica in background e propone "Riavvia".
Future<void> checkForUpdates(BuildContext context) async {
  if (kTestMode) return; // la versione da GitHub non viene dal Play Store
  try {
    final info = await InAppUpdate.checkForUpdate();
    if (info.updateAvailability != UpdateAvailability.updateAvailable) return;

    final pkg = await PackageInfo.fromPlatform();
    final installed = int.tryParse(pkg.buildNumber) ?? 0;
    final forced = installed < Pro.i.config.minVersionCode;

    if (forced && info.immediateUpdateAllowed) {
      await InAppUpdate.performImmediateUpdate();
      return;
    }
    if (info.flexibleUpdateAllowed) {
      await InAppUpdate.startFlexibleUpdate();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(days: 1),
        content: const Text('Aggiornamento pronto'),
        action: SnackBarAction(label: 'Riavvia', onPressed: InAppUpdate.completeFlexibleUpdate),
      ));
    }
  } catch (_) {
    // Installata fuori dal Play Store o senza rete: niente da fare
  }
}
