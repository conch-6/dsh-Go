import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('real App exports round-trip and can emit exact ZIPs for the Worker contract check', () async {
    final temp = Directory.systemTemp.createTempSync('workshop-contract');
    addTearDown(() => temp.deleteSync(recursive: true));
    final pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    final companion = CompanionPackStore(Directory('${temp.path}/companion'), expectedRuntime: workshopRuntimeDigest());
    await pets.install(workshopZip(temp, {'pack.json': utf8.encode(jsonEncode(workshopPet())), 'idle.png': workshopPng()}));
    await companion.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()}).path);
    final http = FakeWorkshopHttp((_, _, _, _) => throw StateError('unexpected network'));
    final client = WorkshopClient(origin: workshopTestOrigin, cacheFile: File('${temp.path}/catalog.json'), http: http);
    addTearDown(client.close);
    final repository = WorkshopRepository(client: client, packages: LocalWorkshopPackages(pets: pets, companion: companion),
      downloadDirectory: Directory('${temp.path}/downloads'), appVersion: '1.0.15');
    final pet = await repository.preparePet(pets, 'user-cat', File('${temp.path}/pet.zip'), WorkshopPublication(workshopMeta()));
    final character = await repository.prepareCompanion(companion, File('${temp.path}/companion.zip'),
      WorkshopPublication(workshopMeta(kind: 'companion')));
    final reimport = PetLibrary(() async => Directory('${temp.path}/reimport'));
    expect((await reimport.install(pet.file)).id, 'user-cat');
    await companion.install(character.file.path);
    expect(await companion.unavailableReason(), isNull);
    expect(http.requests, isEmpty);

    // Local/CI opt-in evidence only. The default test has no persistent output.
    // These are synthetic fixtures; the moc header is not a renderable model.
    final output = Platform.environment['DSH_WORKSHOP_CONTRACT_OUT'];
    if (output != null && output.isNotEmpty) {
      final folder = Directory(output);
      await folder.create(recursive: true);
      for (final prepared in [pet, character]) {
        final zip = File('${folder.path}/${prepared.metadata.kind}.zip');
        final metadata = File('${folder.path}/${prepared.metadata.kind}.metadata.json');
        if (await zip.exists() || await metadata.exists()) throw StateError('contract_output_exists');
        await prepared.file.copy(zip.path);
        await metadata.writeAsString(jsonEncode(prepared.metadata.toJson()), flush: true);
      }
    }
  });

  test('real App exports preserve referenced Unicode paths and resource bytes across reinstallation', () async {
    final temp = Directory.systemTemp.createTempSync('workshop-contract-unicode');
    addTearDown(() => temp.deleteSync(recursive: true));
    // Pet sheets stay flat in schema 1; the input ZIP may have one top folder.
    // The combining accent is deliberately kept decomposed, without aliases.
    const sheet = '小猫 e\u0301.PNG';
    const model = '角色/e\u0301.MODEL3.JSON';
    const moc = 'e\u0301.MOC3';
    const texture = '贴图 e\u0301.PNG';
    final petPng = workshopPng(), texturePng = workshopPng(1, 1);
    final mocBytes = workshopCharacter()['character/m.moc3']!;
    final petJson = workshopPet();
    ((petJson['animations'] as Map)['idle'] as Map)['sheet'] = sheet;
    final pets = PetLibrary(() async => Directory('${temp.path}/pets'));
    final companion = CompanionPackStore(Directory('${temp.path}/companion'), expectedRuntime: workshopRuntimeDigest());
    await pets.install(workshopZip(temp, {
      '宠物包/pack.json': utf8.encode(jsonEncode(petJson)), '宠物包/$sheet': petPng,
    }));
    await companion.install(workshopZip(temp, {
      ...workshopRuntime(),
      'character/character.json': utf8.encode(jsonEncode({
        'schema': 1, 'name': '本地名字', 'model': model,
        'author': 'Author', 'license': 'CC0-1.0', 'source': 'https://source.example/cat',
      })),
      'character/$model': utf8.encode(jsonEncode({
        'Version': 3, 'FileReferences': {'Moc': moc, 'Textures': [texture]},
      })),
      'character/角色/$moc': mocBytes, 'character/角色/$texture': texturePng,
    }).path);
    final http = FakeWorkshopHttp((_, _, _, _) => throw StateError('unexpected network'));
    final client = WorkshopClient(origin: workshopTestOrigin, cacheFile: File('${temp.path}/catalog.json'), http: http);
    addTearDown(client.close);
    final repository = WorkshopRepository(client: client, packages: LocalWorkshopPackages(pets: pets, companion: companion),
      downloadDirectory: Directory('${temp.path}/downloads'), appVersion: '1.0.15');
    final pet = await repository.preparePet(pets, 'user-cat', File('${temp.path}/pet-unicode.zip'), WorkshopPublication(workshopMeta()));
    final character = await repository.prepareCompanion(companion, File('${temp.path}/companion-unicode.zip'),
      WorkshopPublication(workshopMeta(kind: 'companion')));

    final petFiles = workshopUnzip(pet.file), characterFiles = workshopUnzip(character.file);
    expect(petFiles.keys.toSet(), {'pack.json', sheet});
    expect(pet.files.toSet(), petFiles.keys.toSet());
    final manifest = jsonDecode(utf8.decode(petFiles['pack.json']!)) as Map;
    expect(manifest['id'], pet.metadata.id);
    expect(((manifest['animations'] as Map)['idle'] as Map)['sheet'], sheet);
    expect(petFiles[sheet], orderedEquals(petPng));
    expect(characterFiles.keys.toSet(), {
      'character/character.json', 'character/$model', 'character/角色/$moc', 'character/角色/$texture',
    });
    expect(character.files.toSet(), characterFiles.keys.toSet());
    final config = jsonDecode(utf8.decode(characterFiles['character/character.json']!)) as Map;
    final exportedModel = jsonDecode(utf8.decode(characterFiles['character/$model']!)) as Map;
    expect(config['model'], model);
    expect((exportedModel['FileReferences'] as Map)['Moc'], moc);
    expect((exportedModel['FileReferences'] as Map)['Textures'], [texture]);
    expect(characterFiles['character/角色/$moc'], orderedEquals(mocBytes));
    expect(characterFiles['character/角色/$texture'], orderedEquals(texturePng));
    for (final (json, prepared) in [(manifest, pet), (config, character)]) {
      for (final key in ['author', 'license', 'source']) {
        expect(json[key], prepared.metadata.toJson()[key]);
      }
    }

    final reimport = PetLibrary(() async => Directory('${temp.path}/pet-reimport'));
    expect((await reimport.install(pet.file)).id, 'user-cat');
    expect((await reimport.load('user-cat')).animations['idle']!.sheet, sheet);
    expect(File('${(await reimport.folder('user-cat')).path}/$sheet').readAsBytesSync(), orderedEquals(petPng));
    final reimportCompanion = CompanionPackStore(Directory('${temp.path}/companion-reimport'), expectedRuntime: workshopRuntimeDigest());
    // Provide a runtime through the real installer with an ASCII character.
    // The next install must replace its assets and resolve the Unicode refs.
    await reimportCompanion.install(workshopZip(temp, {...workshopRuntime(), ...workshopCharacter()}).path);
    await reimportCompanion.install(character.file.path);
    expect(await reimportCompanion.unavailableReason(), isNull);
    final root = '${reimportCompanion.pack.path}/character';
    final installedConfig = jsonDecode(File('$root/character.json').readAsStringSync()) as Map;
    final installedModel = jsonDecode(File('$root/$model').readAsStringSync()) as Map;
    expect(installedConfig['model'], model);
    expect((installedModel['FileReferences'] as Map)['Moc'], moc);
    expect((installedModel['FileReferences'] as Map)['Textures'], [texture]);
    expect(File('$root/角色/$moc').readAsBytesSync(), orderedEquals(mocBytes));
    expect(File('$root/角色/$texture').readAsBytesSync(), orderedEquals(texturePng));
    expect(File('$root/m.moc3').existsSync(), isFalse);
    expect(http.requests, isEmpty);

    // This opt-in preserves the two existing ASCII output stems. A default
    // run leaves no files, and these synthetic MOC bytes do not exercise Core.
    final output = Platform.environment['DSH_WORKSHOP_CONTRACT_OUT'];
    if (output != null && output.isNotEmpty) {
      final folder = Directory(output);
      await folder.create(recursive: true);
      for (final prepared in [pet, character]) {
        final stem = '${prepared.metadata.kind}-unicode';
        final zip = File('${folder.path}/$stem.zip');
        final metadata = File('${folder.path}/$stem.metadata.json');
        if (await zip.exists() || await metadata.exists()) throw StateError('contract_output_exists');
        await prepared.file.copy(zip.path);
        await metadata.writeAsString(jsonEncode(prepared.metadata.toJson()), flush: true);
      }
    }
  });
}
