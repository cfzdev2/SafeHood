import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../community/data/community_profile_service.dart';
import '../../community/domain/community_profile.dart';
import '../data/location_service.dart';
import '../data/user_profile_service.dart';
import '../domain/app_user.dart';
import 'location_picker_screen.dart';

class AccountSetupScreen extends StatefulWidget {
  final bool isOnboarding;
  final AppUser? initialUser;

  const AccountSetupScreen({
    super.key,
    this.isOnboarding = false,
    this.initialUser,
  });

  @override
  State<AccountSetupScreen> createState() =>
      _AccountSetupScreenState();
}

class _AccountSetupScreenState
    extends State<AccountSetupScreen> {
  final firstNameController =
      TextEditingController();

  final phoneController =
      TextEditingController();

  final addressController =
      TextEditingController();

  final UserProfileService profileService =
      UserProfileService();

  final CommunityProfileService
      communityProfileService =
      CommunityProfileService();

  final LocationService locationService =
      LocationService();

  double? selectedLatitude;
  double? selectedLongitude;

  bool isSaving = false;
  bool isLoadingAddress = false;

  @override
  void initState() {
    super.initState();

    final user = widget.initialUser;

    if (user != null) {
      firstNameController.text =
          user.firstName;

      phoneController.text =
          user.phoneNumber;

      addressController.text =
          user.address;

      selectedLatitude =
          user.latitude;

      selectedLongitude =
          user.longitude;
    }
  }

  @override
  void dispose() {
    firstNameController.dispose();
    phoneController.dispose();
    addressController.dispose();

    super.dispose();
  }

  Future<void> openLocationPicker() async {
    final result =
        await Navigator.of(context)
            .push<LocationPickerResult>(
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialLatitude:
              selectedLatitude,
          initialLongitude:
              selectedLongitude,
        ),
      ),
    );

    if (result == null) {
      return;
    }

    setState(() {
      selectedLatitude =
          result.latitude;

      selectedLongitude =
          result.longitude;

      isLoadingAddress = true;
    });

    final address =
        await locationService
            .addressFromCoordinates(
      result.latitude,
      result.longitude,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      addressController.text = address;
      isLoadingAddress = false;
    });
  }

  Future<void> saveAccount() async {
    debugPrint('SAVE ACCOUNT: START');

    final firstName =
        firstNameController.text.trim();

    final phoneNumber =
        phoneController.text.trim();

    final latitude =
        selectedLatitude;

    final longitude =
        selectedLongitude;

    debugPrint(
      'SAVE ACCOUNT: '
      'firstName=$firstName, '
      'phone=$phoneNumber, '
      'lat=$latitude, '
      'lng=$longitude',
    );

    if (firstName.isEmpty ||
        phoneNumber.isEmpty) {
      debugPrint(
        'SAVE ACCOUNT: BRAK IMIENIA LUB TELEFONU',
      );

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Uzupełnij imię i numer telefonu.',
          ),
        ),
      );

      return;
    }

    if (latitude == null ||
        longitude == null) {
      debugPrint(
        'SAVE ACCOUNT: BRAK LOKALIZACJI',
      );

      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content: Text(
            'Wybierz lokalizację domu na mapie.',
          ),
        ),
      );

      return;
    }

    final firebaseUser =
        FirebaseAuth.instance.currentUser;

    if (firebaseUser == null) {
      debugPrint(
        'SAVE ACCOUNT: BRAK ZALOGOWANEGO UŻYTKOWNIKA',
      );

      return;
    }

    debugPrint(
      'SAVE ACCOUNT: UID=${firebaseUser.uid}',
    );

    setState(() {
      isSaving = true;
    });

    try {
      final address =
          addressController.text
                  .trim()
                  .isEmpty
              ? 'Lokalizacja wybrana na mapie'
              : addressController.text.trim();

      debugPrint(
        'SAVE ACCOUNT: adres=$address',
      );

      final profile = AppUser(
        id: firebaseUser.uid,
        firstName: firstName,
        phoneNumber: phoneNumber,
        address: address,
        latitude: latitude,
        longitude: longitude,
        notificationsEnabled:
            widget.initialUser
                    ?.notificationsEnabled ??
                true,
      );

      debugPrint(
        'SAVE ACCOUNT: '
        'zapisuję users/${profile.id}',
      );

      await profileService
          .saveProfile(profile);

      debugPrint(
        'SAVE ACCOUNT: profil users zapisany',
      );

      final communityProfile =
          CommunityProfile(
        id: firebaseUser.uid,
        firstName: firstName,
        notificationsEnabled:
            profile.notificationsEnabled,
      );

      debugPrint(
        'SAVE ACCOUNT: '
        'zapisuję communityProfiles/${communityProfile.id}',
      );

      await communityProfileService
          .saveCommunityProfile(
        communityProfile,
      );

      debugPrint(
        'SAVE ACCOUNT: GOTOWE',
      );

      if (!mounted) {
        return;
      }

      if (!widget.isOnboarding) {
        Navigator.of(context)
            .pop(profile);
      }
    } catch (error, stackTrace) {
      debugPrint(
        'SAVE ACCOUNT ERROR: $error',
      );

      debugPrint(
        'SAVE ACCOUNT STACKTRACE: $stackTrace',
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Nie udało się zapisać profilu: '
            '$error',
          ),
        ),
      );
    } finally {
      debugPrint(
        'SAVE ACCOUNT: FINALLY',
      );

      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasLocation =
        selectedLatitude != null &&
        selectedLongitude != null;

    return Scaffold(
      appBar: widget.isOnboarding
          ? null
          : AppBar(
              title: const Text(
                'Konfiguracja konta',
              ),
            ),
      body: SafeArea(
        child: ListView(
          padding:
              const EdgeInsets.all(16),
          children: [
            const SizedBox(height: 24),

            Text(
              widget.isOnboarding
                  ? 'Dokończ konfigurację'
                  : 'Edytuj swój profil',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(
                    fontWeight:
                        FontWeight.bold,
                  ),
            ),

            const SizedBox(height: 8),

            const Text(
              'Wybierz lokalizację domu na mapie. '
              'Na jej podstawie SafeHood określi '
              'lokalną społeczność w promieniu 1 km.',
            ),

            const SizedBox(height: 24),

            TextField(
              controller:
                  firstNameController,
              textCapitalization:
                  TextCapitalization.words,
              decoration:
                  const InputDecoration(
                labelText: 'Imię',
                prefixIcon: Icon(
                  Icons.person_outline,
                ),
                border:
                    OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 16),

            TextField(
              controller:
                  phoneController,
              keyboardType:
                  TextInputType.phone,
              decoration:
                  const InputDecoration(
                labelText:
                    'Numer telefonu',
                prefixIcon: Icon(
                  Icons.phone_outlined,
                ),
                border:
                    OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 16),

            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(
                  16,
                ),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          hasLocation
                              ? Icons
                                  .location_on
                              : Icons
                                  .location_off_outlined,
                        ),
                        const SizedBox(
                          width: 12,
                        ),
                        Expanded(
                          child: Text(
                            hasLocation
                                ? 'Lokalizacja domu wybrana'
                                : 'Lokalizacja domu nie została wybrana',
                            style: const TextStyle(
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),

                    if (hasLocation) ...[
                      const SizedBox(
                        height: 12,
                      ),

                      if (isLoadingAddress)
                        const Row(
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(
                                strokeWidth:
                                    2,
                              ),
                            ),
                            SizedBox(
                              width: 12,
                            ),
                            Text(
                              'Ustalam adres...',
                            ),
                          ],
                        )
                      else
                        Text(
                          addressController
                                  .text
                                  .isEmpty
                              ? 'Lokalizacja wybrana na mapie'
                              : addressController
                                  .text,
                        ),
                    ],

                    const SizedBox(
                      height: 16,
                    ),

                    OutlinedButton.icon(
                      onPressed:
                          openLocationPicker,
                      icon: const Icon(
                        Icons.map_outlined,
                      ),
                      label: Text(
                        hasLocation
                            ? 'Zmień lokalizację na mapie'
                            : 'Wybierz lokalizację na mapie',
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            const Card(
              child: Padding(
                padding:
                    EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    Icon(
                      Icons.lock_outline,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Dokładna lokalizacja '
                        'nie będzie publicznie '
                        'wyświetlana innym '
                        'użytkownikom.',
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            FilledButton(
              onPressed: isSaving
                  ? null
                  : saveAccount,
              child: Padding(
                padding:
                    const EdgeInsets
                        .symmetric(
                  vertical: 14,
                ),
                child: isSaving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child:
                            CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'Zapisz i kontynuuj',
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}