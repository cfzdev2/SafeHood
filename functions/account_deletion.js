"use strict";

const {
  FieldValue,
} = require("firebase-admin/firestore");

const deletionBatchSize = 250;

/**
 * Usuwa dokumenty zwrócone przez zapytanie.
 *
 * @param {Object} db Firestore Admin.
 * @param {Object} query Zapytanie Firestore.
 * @return {Promise<number>} Liczba usuniętych dokumentów.
 */
async function deleteQueryDocuments(
    db,
    query,
) {
  let deletedCount = 0;
  let hasMoreDocuments = true;

  while (hasMoreDocuments) {
    const snapshot =
        await query
            .limit(deletionBatchSize)
            .get();

    if (snapshot.empty) {
      break;
    }

    const batch = db.batch();

    for (const document of snapshot.docs) {
      batch.delete(document.ref);
    }

    await batch.commit();

    deletedCount += snapshot.size;
    hasMoreDocuments =
    snapshot.size === deletionBatchSize;
  }

  return deletedCount;
}

/**
 * Usuwa wskazane referencje w bezpiecznych partiach.
 *
 * @param {Object} db Firestore Admin.
 * @param {Array<Object>} references Referencje dokumentów.
 * @return {Promise<number>} Liczba obsłużonych referencji.
 */
async function deleteDocumentReferences(
    db,
    references,
) {
  for (
    let offset = 0;
    offset < references.length;
    offset += deletionBatchSize
  ) {
    const batch = db.batch();

    const part = references.slice(
        offset,
        offset + deletionBatchSize,
    );

    for (const reference of part) {
      batch.delete(reference);
    }

    await batch.commit();
  }

  return references.length;
}
/**
 * Usuwa zgłoszenia użytkownika oraz jego dane
 * z cudzych zgłoszeń.
 *
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID usuwanego użytkownika.
 * @param {Object} incidentsSnapshot Zgłoszenia użytkownika.
 * @return {Promise<Object>} Statystyki usuwania.
 */
async function cleanAccountIncidents(
    db,
    uid,
    incidentsSnapshot,
) {
  let deletedIncidentCount = 0;
  let updatedIncidentCount = 0;
  let deletedMessageCount = 0;

  for (const incidentDocument of incidentsSnapshot.docs) {
    const incident =
        incidentDocument.data() || {};

    if (incident.reporterId === uid) {
      await db.recursiveDelete(
          incidentDocument.ref,
      );

      deletedIncidentCount += 1;

      continue;
    }

    deletedMessageCount +=
        await deleteQueryDocuments(
            db,
            incidentDocument.ref
                .collection("messages")
                .where(
                    "senderId",
                    "==",
                    uid,
                ),
        );

    await Promise.all([
      incidentDocument.ref.update({
        participantIds:
            FieldValue.arrayRemove(uid),
      }),
      incidentDocument.ref
          .collection("responses")
          .doc(uid)
          .delete(),
    ]);

    updatedIncidentCount += 1;
  }

  return {
    deletedIncidentCount,
    updatedIncidentCount,
    deletedMessageCount,
  };
}
/**
 * Pobiera dane potrzebne do usunięcia konta.
 *
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID użytkownika.
 * @return {Promise<Object>} Kontekst usuwania konta.
 */
async function loadAccountDeletionContext(
    db,
    uid,
) {
  const userRef =
      db
          .collection("users")
          .doc(uid);

  const [
    camerasSnapshot,
    incidentsSnapshot,
  ] = await Promise.all([
    userRef
        .collection("cameras")
        .get(),
    db
        .collection("incidents")
        .where(
            "participantIds",
            "array-contains",
            uid,
        )
        .get(),
  ]);

  const cameraIds =
      new Set();

  for (
    const cameraDocument of
    camerasSnapshot.docs
  ) {
    const camera =
        cameraDocument.data() || {};

    const cameraId =
        typeof camera.cameraId === "string" &&
        camera.cameraId.trim() ?
          camera.cameraId.trim() :
          cameraDocument.id;

    cameraIds.add(cameraId);
  }

  const stateReferences =
      [...cameraIds].map(
          (cameraId) => {
            return db
                .collection(
                    "cameraEventStates",
                )
                .doc(
                    `${uid}_${cameraId}_detection`,
                );
          },
      );

  return {
    userRef,
    incidentsSnapshot,
    stateReferences,
  };
}
/**
 * Usuwa dane konta zapisane w kolekcjach
 * backendowych najwyższego poziomu.
 *
 * @param {Object} db Firestore Admin.
 * @param {string} uid UID użytkownika.
 * @param {Array<Object>} stateReferences Stany kamer.
 * @return {Promise<Object>} Statystyki usuwania.
 */
async function deleteAccountTopLevelData(
    db,
    uid,
    stateReferences,
) {
  const deletedBridgeCredentialCount =
      await deleteQueryDocuments(
          db,
          db
              .collection(
                  "bridgeCredentials",
              )
              .where(
                  "ownerId",
                  "==",
                  uid,
              ),
      );

  const deletedPairingCodeCount =
      await deleteQueryDocuments(
          db,
          db
              .collection(
                  "bridgePairingCodes",
              )
              .where(
                  "ownerId",
                  "==",
                  uid,
              ),
      );

  const deletedStateCount =
      await deleteDocumentReferences(
          db,
          stateReferences,
      );

  const deletedCameraEventCount =
      await deleteQueryDocuments(
          db,
          db
              .collection("cameraEvents")
              .where(
                  "ownerId",
                  "==",
                  uid,
              ),
      );

  return {
    deletedBridgeCredentialCount,
    deletedPairingCodeCount,
    deletedStateCount,
    deletedCameraEventCount,
  };
}
/**
 * Usuwa wszystkie dane Firestore należące
 * do wskazanego konta.
 *
 * Konto Firebase Auth należy usunąć dopiero
 * po pomyślnym zakończeniu tej funkcji.
 *
 * @param {Object} options Opcje usuwania.
 * @param {Object} options.db Firestore Admin.
 * @param {string} options.uid UID użytkownika.
 * @return {Promise<Object>} Statystyki usuwania.
 */
async function deleteAccountData({
  db,
  uid,
}) {
  if (
    typeof uid !== "string" ||
    !uid
  ) {
    throw new TypeError(
        "Brak UID usuwanego konta.",
    );
  }

  const context =
      await loadAccountDeletionContext(
          db,
          uid,
      );

  const topLevelResult =
      await deleteAccountTopLevelData(
          db,
          uid,
          context.stateReferences,
      );

  const incidentResult =
      await cleanAccountIncidents(
          db,
          uid,
          context.incidentsSnapshot,
      );

  await db.recursiveDelete(
      context.userRef,
  );

  await db
      .collection("communityProfiles")
      .doc(uid)
      .delete();

  return {
    ...topLevelResult,
    ...incidentResult,
  };
}

module.exports = {
  deleteAccountData,
};
