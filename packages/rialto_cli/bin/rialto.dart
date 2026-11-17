import 'dart:io';

import 'package:rialto_cli/rialto_cli.dart';

Future<void> main(List<String> args) async => exit(await runRialto(args));
