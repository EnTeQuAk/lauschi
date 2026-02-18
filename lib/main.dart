import 'package:flutter/material.dart';

import 'spike/spike_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _SpikeRoot());
}

class _SpikeRoot extends StatelessWidget {
  const _SpikeRoot();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'lauschi spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(useMaterial3: true),
      home: const SpikeApp(),
    );
  }
}
