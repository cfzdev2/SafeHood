const {
  createHash,
  randomBytes,
  randomInt,
  timingSafeEqual,
} = require("node:crypto");

const {
  onCall,
  onRequest,
  HttpsError,
} = require("firebase-functions/v2/https");

const {
  runManufacturerEventOnce,
} = require(
    "./manufacturer_event_deduplicator",
);

const {
  initializeApp,
} = require("firebase-admin/app");

const {
  FieldValue,
  getFirestore,
  Timestamp,
} = require("firebase-admin/firestore");

const {
  getMessaging,
} = require("firebase-admin/messaging");

const geofire =
    require("geofire-common");

initializeApp();

const db = getFirestore();

const radiusInM = 1000;

const allowedIncidentTypes =
    new Set([
      "Podejrzana osoba",
      "Próba włamania",
      "Kradzież",
      "Podejrzany pojazd",
      "Nietypowa aktywność",
      "Inne",
    ]);

const allowedCameraEventTypes = new Set([
  "motion",
  "person",
  "vehicle",
  "sound",
  "tamper",
  "camera_offline",
  "camera_online",
]);

const allowedBridgeMonitoringStatuses =
    new Set([
      "unknown",
      "connecting",
      "online",
      "reconnecting",
      "offline",
    ]);

const cameraEventPriority = {
  motion: 10,
  sound: 20,
  vehicle: 30,
  person: 40,
  tamper: 50,
};

const cameraEventMergeWindowMs =
        15 * 1000;

const bridgePairingLifetimeMs =
    10 * 60 * 1000;

const allowedResponseStatuses =
    new Set([
      "watching",
      "going",
      "onSite",
    ]);

/**
 * Usuwa z kodu parowania wszystkie
 * znaki poza cyframi.
 *
 * @param {unknown} value Kod otrzymany od klienta.
 * @return {string} Oczyszczony kod.
 */
function normalizeBridgePairingCode(value) {
  if (typeof value !== "string") {
    return "";
  }

  return value.replace(
      /[^0-9]/g,
      "",
  );
}

/**
 * Tworzy skrót wartości poufnej.
 *
 * @param {string} value Wartość do zabezpieczenia.
 * @return {string} Skrót SHA-256.
 */
function hashBridgeValue(value) {
  return createHash("sha256")
      .update(value, "utf8")
      .digest("hex");
}
/**
 * Porównuje dwa skróty bez ujawniania,
 * w którym miejscu się różnią.
 *
 * @param {string} first Pierwszy skrót.
 * @param {string} second Drugi skrót.
 * @return {boolean} Czy skróty są identyczne.
 */
function bridgeHashesAreEqual(
    first,
    second,
) {
  if (
    typeof first !== "string" ||
    typeof second !== "string" ||
    first.length !== second.length
  ) {
    return false;
  }

  const firstBuffer =
      Buffer.from(
          first,
          "utf8",
      );

  const secondBuffer =
      Buffer.from(
          second,
          "utf8",
      );

  return timingSafeEqual(
      firstBuffer,
      secondBuffer,
  );
}

/**
 * Sprawdza dane uwierzytelniające Bridge.
 *
 * @param {Object} request Żądanie HTTP.
 * @return {Promise<Object|null>} Tożsamość Bridge
 * lub null.
 */
async function authenticateBridgeRequest(
    request,
) {
  const bridgeIdHeader =
      request.headers[
          "x-safehood-bridge-id"
      ];

  const authorizationHeader =
      request.headers.authorization;

  const bridgeId =
      typeof bridgeIdHeader === "string" ?
        bridgeIdHeader.trim() :
        "";

  const authorization =
      typeof authorizationHeader === "string" ?
        authorizationHeader.trim() :
        "";

  if (
    !bridgeId ||
    !authorization.startsWith(
        "Bearer ",
    )
  ) {
    return null;
  }

  const bridgeSecret =
      authorization
          .substring(
              "Bearer ".length,
          )
          .trim();

  if (!bridgeSecret) {
    return null;
  }

  const credentialsSnapshot =
      await db
          .collection(
              "bridgeCredentials",
          )
          .doc(bridgeId)
          .get();

  if (!credentialsSnapshot.exists) {
    return null;
  }

  const credentials =
      credentialsSnapshot.data();

  if (
    credentials.status !== "active" ||
    typeof credentials.ownerId !==
      "string" ||
    typeof credentials.secretHash !==
      "string"
  ) {
    return null;
  }

  const receivedHash =
      hashBridgeValue(
          bridgeSecret,
      );

  if (
    !bridgeHashesAreEqual(
        credentials.secretHash,
        receivedHash,
    )
  ) {
    return null;
  }

  return {
    bridgeId,
    ownerId:
        credentials.ownerId,
  };
}
/**
 * Generuje ośmiocyfrowy kod parowania.
 *
 * @return {string} Kod bez separatora.
 */
function generateBridgePairingCode() {
  return randomInt(
      0,
      100000000,
  )
      .toString()
      .padStart(8, "0");
}

/**
 * Formatuje kod do postaci 1234-5678.
 *
 * @param {string} code Kod bez separatora.
 * @return {string} Kod do pokazania użytkownikowi.
 */
function formatBridgePairingCode(code) {
  return (
    `${code.substring(0, 4)}-` +
    `${code.substring(4)}`
  );
}
/**
 * Pobiera użytkownika oraz osoby
 * znajdujące się maksymalnie 1 km od niego.
 *
 * @param {string} uid UID użytkownika.
 * @return {Promise<Object>} Dane użytkownika
 * i pobliskich osób.
 */
async function getNearbyContext(uid) {
  const currentUserSnapshot =
      await db
          .collection("users")
          .doc(uid)
          .get();

  if (!currentUserSnapshot.exists) {
    throw new HttpsError(
        "not-found",
        "Nie znaleziono profilu użytkownika.",
    );
  }

  const currentUser =
      currentUserSnapshot.data();

  const currentGeo =
      currentUser.geo;

  if (!currentGeo ||
      !currentGeo.geopoint) {
    throw new HttpsError(
        "failed-precondition",
        "Profil nie ma zapisanej lokalizacji.",
    );
  }

  const currentPoint =
      currentGeo.geopoint;

  const center = [
    currentPoint.latitude,
    currentPoint.longitude,
  ];

  const bounds =
      geofire.geohashQueryBounds(
          center,
          radiusInM,
      );

  const queries =
      bounds.map((bound) => {
        return db
            .collection("users")
            .orderBy("geo.geohash")
            .startAt(bound[0])
            .endAt(bound[1])
            .get();
      });

  const snapshots =
      await Promise.all(
          queries,
      );

  const nearbyDistances =
      new Map();

  for (const snapshot of snapshots) {
    for (const document of
      snapshot.docs) {
      if (document.id === uid) {
        continue;
      }

      const userData =
          document.data();

      const geo =
          userData.geo;

      if (!geo ||
          !geo.geopoint) {
        continue;
      }

      const point =
          geo.geopoint;

      const distanceInKm =
          geofire.distanceBetween(
              [
                point.latitude,
                point.longitude,
              ],
              center,
          );

      const distanceInM =
          Math.round(
              distanceInKm * 1000,
          );

      if (distanceInM <=
          radiusInM) {
        nearbyDistances.set(
            document.id,
            distanceInM,
        );
      }
    }
  }

  const nearbyUsers = [];

  for (const [
    userId,
    distanceMeters,
  ] of nearbyDistances.entries()) {
    const profileSnapshot =
        await db
            .collection(
                "communityProfiles",
            )
            .doc(userId)
            .get();

    if (!profileSnapshot.exists) {
      continue;
    }

    const profile =
        profileSnapshot.data();

    nearbyUsers.push({
      id: userId,
      firstName:
          profile.firstName ||
          "Użytkownik",
      distanceMeters,
    });
  }

  nearbyUsers.sort(
      (a, b) =>
        a.distanceMeters -
        b.distanceMeters,
  );

  return {
    currentUser,
    nearbyUsers,
  };
}

/**
 * Wysyła gotowe wiadomości FCM.
 *
 * @param {Array<Object>} messages
 * Wiadomości do wysłania.
 * @return {Promise<void>}
 */
async function sendPushMessages(
    messages,
) {
  if (messages.length === 0) {
    console.log(
        "PUSH: brak urządzeń do powiadomienia",
    );

    return;
  }

  for (
    let index = 0;
    index < messages.length;
    index += 500
  ) {
    const batch =
        messages.slice(
            index,
            index + 500,
        );

    const result =
        await getMessaging()
            .sendEach(batch);

    console.log(
        "PUSH: wysłano =",
        result.successCount,
    );

    console.log(
        "PUSH: błędy =",
        result.failureCount,
    );

    result.responses.forEach(
        (
            response,
            responseIndex,
        ) => {
          if (response.success) {
            return;
          }

          console.error(
              "PUSH ERROR:",
              batch[responseIndex]
                  .token,
              response.error,
          );
        },
    );
  }
}

/**
 * Pobiera urządzenia użytkownika.
 *
 * @param {string} uid UID użytkownika.
 * @return {Promise<Array<string>>}
 * Tokeny FCM.
 */
async function getUserFcmTokens(uid) {
  const devicesSnapshot =
      await db
          .collection("users")
          .doc(uid)
          .collection("devices")
          .where(
              "notificationsAllowed",
              "==",
              true,
          )
          .get();

  const tokens = [];

  for (const document of
    devicesSnapshot.docs) {
    const device =
        document.data();

    const token =
        typeof device.fcmToken ===
        "string" ?
          device.fcmToken.trim() :
          "";

    if (token) {
      tokens.push(token);
    }
  }

  return tokens;
}

/**
 * Wysyła jedno powiadomienie
 * wskazanym użytkownikom.
 *
 * @param {Object} options Opcje.
 * @param {Array<string>} options.userIds
 * UID odbiorców.
 * @param {string} options.title Tytuł.
 * @param {string} options.body Treść.
 * @param {Object<string, string>} options.data
 * Dane deep-linku.
 * @return {Promise<void>}
 */
async function sendNotificationToUsers({
  userIds,
  title,
  body,
  data,
}) {
  const uniqueUserIds = [
    ...new Set(
        userIds.filter(
            (id) => Boolean(id),
        ),
    ),
  ];

  const messages = [];

  for (const userId of
    uniqueUserIds) {
    const tokens =
        await getUserFcmTokens(
            userId,
        );

    for (const token of tokens) {
      messages.push({
        notification: {
          title,
          body,
        },
        data,
        android: {
          priority: "high",
        },
        token,
      });
    }
  }

  await sendPushMessages(
      messages,
  );
}

/**
 * Wysyła alarm nowego zgłoszenia
 * pobliskim użytkownikom.
 *
 * @param {Object} options Opcje.
 * @param {string} options.reporterId
 * UID zgłaszającego.
 * @param {string} options.reporterName
 * Imię zgłaszającego.
 * @param {string} options.incidentId
 * ID zgłoszenia.
 * @param {string} options.title
 * Rodzaj zdarzenia.
 * @param {Array<Object>} options.nearbyUsers
 * Pobliskie osoby.
 * @return {Promise<void>}
 */
async function sendIncidentNotifications({
  reporterId,
  reporterName,
  incidentId,
  title,
  nearbyUsers,
}) {
  const messages = [];

  for (const nearbyUser of
    nearbyUsers) {
    const tokens =
        await getUserFcmTokens(
            nearbyUser.id,
        );

    for (const token of tokens) {
      messages.push({
        notification: {
          title:
              `${reporterName} potrzebuje pomocy`,
          body:
              `${title} • ` +
              `${nearbyUser.distanceMeters} m ` +
              "od Ciebie",
        },
        data: {
          type: "incident",
          incidentId,
          reporterId,
        },
        android: {
          priority: "high",
        },
        token,
      });
    }
  }

  await sendPushMessages(
      messages,
  );
}

/**
 * Sprawdza, czy zgłoszenie nadal
 * jest aktywne.
 *
 * @param {Object} incident Dane zgłoszenia.
 * @return {boolean} Czy jest aktywne.
 */
function isIncidentActive(incident) {
  if (incident.status !== "active") {
    return false;
  }

  const expiresAt =
      incident.expiresAt;

  if (!expiresAt ||
      typeof expiresAt.toMillis !==
      "function") {
    return false;
  }

  return expiresAt.toMillis() >
      Date.now();
}

/**
 * Pobiera zgłoszenie i sprawdza,
 * czy użytkownik jest uczestnikiem.
 *
 * @param {string} incidentId ID zgłoszenia.
 * @param {string} uid UID użytkownika.
 * @return {Promise<Object>} Referencja
 * i dane zgłoszenia.
 */
async function getIncidentForParticipant(
    incidentId,
    uid,
) {
  const reference =
      db.collection("incidents")
          .doc(incidentId);

  const snapshot =
      await reference.get();

  if (!snapshot.exists) {
    throw new HttpsError(
        "not-found",
        "Nie znaleziono zgłoszenia.",
    );
  }

  const incident =
      snapshot.data();

  const participantIds =
      Array.isArray(
          incident.participantIds,
      ) ?
        incident.participantIds :
        [];

  if (!participantIds.includes(uid)) {
    throw new HttpsError(
        "permission-denied",
        "Nie masz dostępu do tego zgłoszenia.",
    );
  }

  return {
    reference,
    incident,
    participantIds,
  };
}

exports.getNearbyUsers = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const uid =
          request.auth.uid;

      const context =
          await getNearbyContext(
              uid,
          );

      return {
        users:
            context.nearbyUsers,
      };
    },
);

exports.createIncident = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const uid =
          request.auth.uid;

      const data =
          request.data || {};

      const cameraId =
          typeof data.cameraId ===
          "string" ?
            data.cameraId.trim() :
            "";

      const title =
          typeof data.title ===
          "string" ?
            data.title.trim() :
            "";

      const description =
          typeof data.description ===
          "string" ?
            data.description.trim() :
            "";

      if (!cameraId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora kamery.",
        );
      }

      if (!allowedIncidentTypes
          .has(title)) {
        throw new HttpsError(
            "invalid-argument",
            "Nieprawidłowy rodzaj zgłoszenia.",
        );
      }

      if (description.length > 500) {
        throw new HttpsError(
            "invalid-argument",
            "Opis może mieć maksymalnie 500 znaków.",
        );
      }

      const cameraSnapshot =
          await db
              .collection("users")
              .doc(uid)
              .collection("cameras")
              .doc(cameraId)
              .get();

      if (!cameraSnapshot.exists) {
        throw new HttpsError(
            "not-found",
            "Nie znaleziono kamery.",
        );
      }

      const cameraData =
          cameraSnapshot.data();

      const nearbyContext =
          await getNearbyContext(
              uid,
          );

      const currentUser =
          nearbyContext.currentUser;

      const nearbyUsers =
          nearbyContext.nearbyUsers;

      const reporterName =
          currentUser.firstName ||
          "Użytkownik";

      const cameraName =
          cameraData.name ||
          "Kamera";

      const participantIds = [
        uid,
        ...nearbyUsers.map(
            (user) => user.id,
        ),
      ];

      const nowMillis =
          Date.now();

      const expiresAtMillis =
          nowMillis +
          60 * 60 * 1000;

      const document =
          db.collection("incidents")
              .doc();

      await document.set({
        reporterId: uid,
        reporterName,
        cameraId,
        cameraName,
        title,
        description:
            description.length > 0 ?
              description :
              null,
        createdAt:
            Timestamp.fromMillis(
                nowMillis,
            ),
        expiresAt:
            Timestamp.fromMillis(
                expiresAtMillis,
            ),
        status: "active",
        hasRecording: false,
        recordingDurationSeconds:
            null,
        participantIds,
      });

      try {
        await sendIncidentNotifications({
          reporterId: uid,
          reporterName,
          incidentId:
              document.id,
          title,
          nearbyUsers,
        });
      } catch (error) {
        console.error(
            "PUSH: nie udało się wysłać " +
            "powiadomień o zgłoszeniu",
            error,
        );
      }

      return {
        id: document.id,
        reporterId: uid,
        reporterName,
        cameraId,
        cameraName,
        title,
        description:
            description.length > 0 ?
              description :
              null,
        createdAtMillis:
            nowMillis,
        expiresAtMillis,
        participantIds,
        participantCount:
            participantIds.length,
      };
    },
);
/**
 * Eskaluje CameraEvent do zgłoszenia społeczności.
 *
 * Tworzenie Incident i powiązanie eventu
 * odbywa się atomowo w jednej transakcji.
 */
exports.escalateCameraEvent = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const uid =
          request.auth.uid;

      const data =
          request.data || {};

      const eventId =
          typeof data.eventId ===
          "string" ?
            data.eventId.trim() :
            "";

      const title =
          typeof data.title ===
          "string" ?
            data.title.trim() :
            "";

      const description =
          typeof data.description ===
          "string" ?
            data.description.trim() :
            "";

      if (!eventId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora wykrycia.",
        );
      }

      if (!allowedIncidentTypes
          .has(title)) {
        throw new HttpsError(
            "invalid-argument",
            "Nieprawidłowy rodzaj zgłoszenia.",
        );
      }

      if (description.length > 500) {
        throw new HttpsError(
            "invalid-argument",
            "Opis może mieć maksymalnie 500 znaków.",
        );
      }

      const eventReference =
          db.collection("cameraEvents")
              .doc(eventId);

      const initialEventSnapshot =
          await eventReference.get();

      if (!initialEventSnapshot.exists) {
        throw new HttpsError(
            "not-found",
            "Nie znaleziono wykrycia.",
        );
      }

      const initialEvent =
          initialEventSnapshot.data();

      if (initialEvent.ownerId !== uid) {
        throw new HttpsError(
            "permission-denied",
            "To wykrycie nie należy do Ciebie.",
        );
      }

      if (initialEvent.status ===
          "dismissed") {
        throw new HttpsError(
            "failed-precondition",
            "To wykrycie zostało już " +
            "oznaczone jako niegroźne.",
        );
      }

      const existingIncidentId =
          typeof initialEvent.incidentId ===
                  "string" &&
              initialEvent.incidentId.trim() ?
            initialEvent.incidentId.trim() :
            "";

      if (initialEvent.status ===
              "escalated" &&
          existingIncidentId) {
        return {
          id: existingIncidentId,
          eventId,
          alreadyEscalated: true,
        };
      }

      const cameraId =
          typeof initialEvent.cameraId ===
                  "string" ?
            initialEvent.cameraId.trim() :
            "";

      if (!cameraId) {
        throw new HttpsError(
            "failed-precondition",
            "Wykrycie nie ma " +
            "przypisanej kamery.",
        );
      }

      const nearbyContext =
          await getNearbyContext(
              uid,
          );

      const currentUser =
          nearbyContext.currentUser;

      const nearbyUsers =
          nearbyContext.nearbyUsers;

      const reporterName =
          currentUser.firstName ||
          "Użytkownik";

      const participantIds = [
        uid,
        ...nearbyUsers.map(
            (user) => user.id,
        ),
      ];

      const nowMillis =
          Date.now();

      const expiresAtMillis =
          nowMillis +
          60 * 60 * 1000;

      const nowTimestamp =
          Timestamp.fromMillis(
              nowMillis,
          );

      const expiresAtTimestamp =
          Timestamp.fromMillis(
              expiresAtMillis,
          );

      const cameraReference =
          db.collection("users")
              .doc(uid)
              .collection("cameras")
              .doc(cameraId);

      const incidentReference =
          db.collection("incidents")
              .doc();

      const result =
          await db.runTransaction(
              async (transaction) => {
                const eventSnapshot =
                    await transaction.get(
                        eventReference,
                    );

                if (!eventSnapshot.exists) {
                  throw new HttpsError(
                      "not-found",
                      "Nie znaleziono wykrycia.",
                  );
                }

                const event =
                    eventSnapshot.data();

                if (event.ownerId !== uid) {
                  throw new HttpsError(
                      "permission-denied",
                      "To wykrycie nie " +
                      "należy do Ciebie.",
                  );
                }

                const status =
                    typeof event.status ===
                            "string" ?
                      event.status :
                      "new";

                const linkedIncidentId =
                    typeof event.incidentId ===
                            "string" &&
                        event.incidentId.trim() ?
                      event.incidentId.trim() :
                      "";

                if (status === "escalated" &&
                    linkedIncidentId) {
                  return {
                    incidentId:
                        linkedIncidentId,
                    created: false,
                    cameraName: null,
                  };
                }

                if (status === "dismissed") {
                  throw new HttpsError(
                      "failed-precondition",
                      "To wykrycie zostało już " +
                      "oznaczone jako niegroźne.",
                  );
                }

                if (status !== "new" &&
                    status !== "viewed") {
                  throw new HttpsError(
                      "failed-precondition",
                      "Tego wykrycia nie można " +
                      "już zgłosić.",
                  );
                }

                if (event.cameraId !==
                    cameraId) {
                  throw new HttpsError(
                      "failed-precondition",
                      "Kamera wykrycia " +
                      "uległa zmianie.",
                  );
                }

                const cameraSnapshot =
                    await transaction.get(
                        cameraReference,
                    );

                if (!cameraSnapshot.exists) {
                  throw new HttpsError(
                      "not-found",
                      "Nie znaleziono kamery.",
                  );
                }

                const camera =
                    cameraSnapshot.data();

                const cameraName =
                    typeof camera.name ===
                            "string" &&
                        camera.name.trim() ?
                      camera.name.trim() :
                      "Kamera";

                transaction.set(
                    incidentReference,
                    {
                      reporterId: uid,
                      reporterName,
                      cameraId,
                      cameraName,
                      cameraEventId:
                          eventId,
                      title,
                      description:
                          description.length > 0 ?
                            description :
                            null,
                      createdAt:
                          nowTimestamp,
                      expiresAt:
                          expiresAtTimestamp,
                      status: "active",
                      hasRecording:
                          Boolean(
                              event.clipUrl,
                          ),
                      recordingDurationSeconds:
                          null,
                      participantIds,
                    },
                );

                transaction.update(
                    eventReference,
                    {
                      status: "escalated",
                      incidentId:
                          incidentReference.id,
                      updatedAt:
                          nowTimestamp,
                    },
                );

                return {
                  incidentId:
                      incidentReference.id,
                  created: true,
                  cameraName,
                };
              },
          );

      if (result.created) {
        try {
          await sendIncidentNotifications({
            reporterId: uid,
            reporterName,
            incidentId:
                result.incidentId,
            title,
            nearbyUsers,
          });
        } catch (error) {
          console.error(
              "PUSH: nie udało się wysłać " +
              "powiadomień o eskalacji eventu",
              error,
          );
        }
      }

      return {
        id: result.incidentId,
        eventId,
        cameraId,
        cameraName:
            result.cameraName,
        title,
        description:
            description.length > 0 ?
              description :
              null,
        createdAtMillis:
            nowMillis,
        expiresAtMillis,
        participantIds,
        participantCount:
            participantIds.length,
        alreadyEscalated:
            !result.created,
      };
    },
);

exports.sendIncidentMessage = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const uid =
          request.auth.uid;

      const data =
          request.data || {};

      const incidentId =
          typeof data.incidentId ===
          "string" ?
            data.incidentId.trim() :
            "";

      const text =
          typeof data.text ===
          "string" ?
            data.text.trim() :
            "";

      if (!incidentId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora zgłoszenia.",
        );
      }

      if (!text) {
        throw new HttpsError(
            "invalid-argument",
            "Wiadomość nie może być pusta.",
        );
      }

      if (text.length > 500) {
        throw new HttpsError(
            "invalid-argument",
            "Wiadomość może mieć maksymalnie 500 znaków.",
        );
      }

      const result =
          await getIncidentForParticipant(
              incidentId,
              uid,
          );

      const incident =
          result.incident;

      if (!isIncidentActive(
          incident,
      )) {
        throw new HttpsError(
            "failed-precondition",
            "Zgłoszenie nie jest już aktywne.",
        );
      }

      const profileSnapshot =
          await db
              .collection(
                  "communityProfiles",
              )
              .doc(uid)
              .get();

      if (!profileSnapshot.exists) {
        throw new HttpsError(
            "not-found",
            "Nie znaleziono profilu użytkownika.",
        );
      }

      const profile =
          profileSnapshot.data();

      const firstName =
          typeof profile.firstName ===
                  "string" &&
              profile.firstName.trim() ?
            profile.firstName.trim() :
            "Użytkownik";

      const messageReference =
          result.reference
              .collection("messages")
              .doc();

      const now =
          Timestamp.now();

      await messageReference.set({
        userId: uid,
        firstName,
        text,
        createdAt: now,
      });

      const recipients =
          result.participantIds.filter(
              (participantId) =>
                participantId !== uid,
          );

      const pushBody =
          text.length > 120 ?
            `${text.slice(0, 117)}...` :
            text;

      try {
        await sendNotificationToUsers({
          userIds: recipients,
          title:
              `${firstName} napisał na czacie`,
          body: pushBody,
          data: {
            type:
                "incident_chat",
            incidentId,
            messageId:
                messageReference.id,
            senderId: uid,
          },
        });
      } catch (error) {
        console.error(
            "PUSH: nie udało się wysłać " +
            "powiadomienia o wiadomości",
            error,
        );
      }

      return {
        id:
            messageReference.id,
        createdAtMillis:
            now.toMillis(),
      };
    },
);

exports.setIncidentResponse = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const uid =
          request.auth.uid;

      const data =
          request.data || {};

      const incidentId =
          typeof data.incidentId ===
          "string" ?
            data.incidentId.trim() :
            "";

      const status =
          typeof data.status ===
          "string" ?
            data.status.trim() :
            "";

      if (!incidentId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora zgłoszenia.",
        );
      }

      if (!allowedResponseStatuses
          .has(status)) {
        throw new HttpsError(
            "invalid-argument",
            "Nieprawidłowy status reakcji.",
        );
      }

      const result =
          await getIncidentForParticipant(
              incidentId,
              uid,
          );

      const incident =
          result.incident;

      if (incident.reporterId === uid) {
        throw new HttpsError(
            "failed-precondition",
            "Zgłaszający nie ustawia reakcji na własne zgłoszenie.",
        );
      }

      if (!isIncidentActive(
          incident,
      )) {
        throw new HttpsError(
            "failed-precondition",
            "Zgłoszenie nie jest już aktywne.",
        );
      }

      const profileSnapshot =
          await db
              .collection(
                  "communityProfiles",
              )
              .doc(uid)
              .get();

      if (!profileSnapshot.exists) {
        throw new HttpsError(
            "not-found",
            "Nie znaleziono profilu użytkownika.",
        );
      }

      const profile =
          profileSnapshot.data();

      const firstName =
          typeof profile.firstName ===
                  "string" &&
              profile.firstName.trim() ?
            profile.firstName.trim() :
            "Użytkownik";

      const responseReference =
          result.reference
              .collection("responses")
              .doc(uid);

      const previousSnapshot =
          await responseReference.get();

      const previousStatus =
          previousSnapshot.exists ?
            previousSnapshot
                .data()
                .status :
            null;

      await responseReference.set({
        userId: uid,
        firstName,
        status,
        updatedAt:
            Timestamp.now(),
      });

      const statusLabels = {
        watching:
            "Obserwuje sytuację",
        going:
            "Idzie sprawdzić",
        onSite:
            "Jest na miejscu",
      };

      if (previousStatus !== status &&
          incident.reporterId &&
          incident.reporterId !== uid) {
        try {
          await sendNotificationToUsers({
            userIds: [
              incident.reporterId,
            ],
            title:
                `${firstName} reaguje na Twoje zgłoszenie`,
            body:
                statusLabels[status],
            data: {
              type:
                  "incident_response",
              incidentId,
              responderId: uid,
              responseStatus:
                  status,
            },
          });
        } catch (error) {
          console.error(
              "PUSH: nie udało się wysłać " +
              "powiadomienia o reakcji",
              error,
          );
        }
      }

      return {
        status,
      };
    },
);

exports.getIncidentContact = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const uid =
          request.auth.uid;

      const data =
          request.data || {};

      const incidentId =
          typeof data.incidentId ===
          "string" ?
            data.incidentId.trim() :
            "";

      if (!incidentId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora zgłoszenia.",
        );
      }

      const result =
          await getIncidentForParticipant(
              incidentId,
              uid,
          );

      const incident =
          result.incident;

      if (!isIncidentActive(
          incident,
      )) {
        throw new HttpsError(
            "failed-precondition",
            "Zgłoszenie wygasło.",
        );
      }

      const reporterId =
          incident.reporterId;

      if (!reporterId) {
        throw new HttpsError(
            "not-found",
            "Brak danych zgłaszającego.",
        );
      }

      const reporterSnapshot =
          await db
              .collection("users")
              .doc(reporterId)
              .get();

      if (!reporterSnapshot.exists) {
        throw new HttpsError(
            "not-found",
            "Nie znaleziono profilu zgłaszającego.",
        );
      }

      const reporter =
          reporterSnapshot.data();

      const phoneNumber =
          typeof reporter.phoneNumber ===
          "string" ?
            reporter.phoneNumber.trim() :
            "";

      if (!phoneNumber) {
        throw new HttpsError(
            "failed-precondition",
            "Zgłaszający nie ma zapisanego numeru telefonu.",
        );
      }

      return {
        reporterName:
            incident.reporterName ||
            reporter.firstName ||
            "Użytkownik",
        phoneNumber,
      };
    },
);

/**
 * Normalizuje typ zdarzenia kamery.
 *
 * @param {*} value Surowa wartość.
 * @return {string} Typ zdarzenia.
 */
function normalizeCameraEventType(value) {
  if (typeof value !== "string") {
    throw new HttpsError(
        "invalid-argument",
        "Brak typu wykrycia.",
    );
  }

  const type =
      value.trim().toLowerCase();

  if (!allowedCameraEventTypes.has(type)) {
    throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowy typ wykrycia.",
    );
  }

  return type;
}

/**
 * Normalizuje nazwę źródła zdarzenia.
 *
 * @param {*} value Surowe źródło.
 * @return {string} Źródło.
 */
function normalizeCameraEventSource(value) {
  if (typeof value !== "string") {
    return "unknown";
  }

  const source =
      value.trim().toLowerCase();

  if (!source) {
    return "unknown";
  }

  return source.substring(0, 40);
}

/**
 * Normalizuje confidence 0.0 - 1.0.
 *
 * @param {*} value Surowa wartość.
 * @return {number|null} Confidence.
 */
function normalizeConfidence(value) {
  if (typeof value !== "number" ||
      !Number.isFinite(value)) {
    return null;
  }

  return Math.min(
      1,
      Math.max(
          0,
          value,
      ),
  );
}

/**
 * Normalizuje opcjonalny URL.
 *
 * @param {*} value Surowa wartość.
 * @return {string|null} URL.
 */
function normalizeOptionalUrl(value) {
  if (typeof value !== "string") {
    return null;
  }

  const url = value.trim();

  if (!url) {
    return null;
  }

  return url.substring(0, 2048);
}

/**
 * Pobiera bezpieczny czas zdarzenia.
 *
 * Jeśli zegar kamery jest mocno
 * rozjechany, używamy czasu serwera.
 *
 * @param {*} value Czas z urządzenia.
 * @param {number} nowMillis Czas serwera.
 * @return {number} Timestamp millis.
 */
function normalizeOccurredAt(
    value,
    nowMillis,
) {
  let millis = null;

  if (typeof value === "number" &&
      Number.isFinite(value)) {
    millis = value;
  }

  if (typeof value === "string") {
    const parsed =
        Date.parse(value);

    if (!Number.isNaN(parsed)) {
      millis = parsed;
    }
  }

  if (millis === null) {
    return nowMillis;
  }

  const maxClockDifferenceMs =
      10 * 60 * 1000;

  if (Math.abs(
      millis - nowMillis,
  ) > maxClockDifferenceMs) {
    return nowMillis;
  }

  return millis;
}

/**
 * Czy ten typ bierze udział
 * w agregowaniu detekcji.
 *
 * Offline/online będą później miały
 * osobny mechanizm stabilizacji.
 *
 * @param {string} type Typ.
 * @return {boolean} Wynik.
 */
function isDetectionCameraEvent(type) {
  return type === "motion" ||
      type === "person" ||
      type === "vehicle" ||
      type === "sound" ||
      type === "tamper";
}

/**
 * Wybiera ważniejszy typ w obrębie
 * jednego zagregowanego wykrycia.
 *
 * @param {string} currentType Stary typ.
 * @param {string} newType Nowy typ.
 * @return {string} Wybrany typ.
 */
function selectCameraEventType(
    currentType,
    newType,
) {
  const currentPriority =
      cameraEventPriority[currentType] || 0;

  const newPriority =
      cameraEventPriority[newType] || 0;

  if (newPriority > currentPriority) {
    return newType;
  }

  return currentType;
}

/**
 * Łączy confidence.
 *
 * Zachowujemy najwyższą pewność
 * wykrytą w obrębie eventu.
 *
 * @param {*} currentValue Stara wartość.
 * @param {*} newValue Nowa wartość.
 * @return {number|null} Wynik.
 */
function mergeConfidence(
    currentValue,
    newValue,
) {
  const current =
      normalizeConfidence(currentValue);

  const incoming =
      normalizeConfidence(newValue);

  if (current === null) {
    return incoming;
  }

  if (incoming === null) {
    return current;
  }

  return Math.max(
      current,
      incoming,
  );
}

/**
 * Główny silnik przyjmowania
 * zdarzeń z kamery.
 *
 * To jest funkcja wewnętrzna.
 * Później będą ją wywoływały:
 *
 * - ONVIF adapter
 * - webhook producenta
 * - SafeHood Hub
 * - fake camera
 *
 * @param {Object} input Dane zdarzenia.
 * @return {Promise<Object>} Wynik.
 */

/**
 * Wysyła powiadomienie o wykryciu
 * tylko do właściciela kamery.
 *
 * @param {string} ownerId UID właściciela.
 * @param {string} cameraId ID kamery.
 * @param {string} cameraName Nazwa kamery.
 * @param {string} eventId ID CameraEvent.
 * @param {string} eventType Typ zdarzenia.
 * @return {Promise<void>}
 */

/**
 * Sprawdza, czy dla danego typu
 * zdarzenia należy wysłać push.
 *
 * Brak ustawień oznacza zgodę,
 * żeby zachować zgodność ze
 * starszymi kamerami.
 *
 * @param {Object|undefined} settings Ustawienia kamery.
 * @param {string} eventType Typ zdarzenia.
 * @return {boolean}
 */
function isCameraEventNotificationEnabled(
    settings,
    eventType,
) {
  if (!settings ||
      typeof settings !== "object") {
    return true;
  }

  if (settings.enabled === false) {
    return false;
  }

  const settingKeyByType = {
    motion: "motion",
    person: "person",
    vehicle: "vehicle",
    sound: "sound",
  };

  const settingKey =
      settingKeyByType[eventType];

  if (!settingKey) {
    return true;
  }

  return settings[settingKey] !== false;
}
/**
 * Wysyła powiadomienie o wykryciu
 * tylko do właściciela kamery.
 *
 * @param {string} ownerId UID właściciela.
 * @param {string} cameraId ID kamery.
 * @param {string} cameraName Nazwa kamery.
 * @param {string} eventId ID zdarzenia.
 * @param {string} eventType Typ zdarzenia.
 * @return {Promise<void>}
 */
/**
 * Zwraca tytuł powiadomienia
 * odpowiedni dla typu zdarzenia.
 *
 * @param {string} eventType Typ zdarzenia.
 * @return {string}
 */
function getCameraEventNotificationTitle(
    eventType,
) {
  switch (eventType) {
    case "person":
      return "Wykryto osobę";

    case "motion":
      return "Wykryto ruch";

    case "vehicle":
      return "Wykryto pojazd";

    case "sound":
      return "Wykryto dźwięk";

    default:
      return "Wykryto aktywność";
  }
}
/**
 * Wysyła powiadomienie o wykryciu
 * tylko do właściciela kamery.
 *
 * @param {string} ownerId UID właściciela.
 * @param {string} cameraId ID kamery.
 * @param {string} cameraName Nazwa kamery.
 * @param {string} eventId ID zdarzenia.
 * @param {string} eventType Typ zdarzenia.
 * @return {Promise<void>}
 */
async function sendCameraEventNotification({
  ownerId,
  cameraId,
  cameraName,
  eventId,
  eventType,
}) {
  const cameraDocument =
      await db
          .collection("users")
          .doc(ownerId)
          .collection("cameras")
          .doc(cameraId)
          .get();

  const cameraData =
      cameraDocument.data() || {};

  const notificationSettings =
      cameraData.notificationSettings;
  const notificationTitle =
    getCameraEventNotificationTitle(
        eventType,
    );
  if (!isCameraEventNotificationEnabled(
      notificationSettings,
      eventType,
  )) {
    console.log(
        "CAMERA PUSH: wyłączone dla typu",
        eventType,
    );

    return;
  }
  const devicesSnapshot =
      await db
          .collection("users")
          .doc(ownerId)
          .collection("devices")
          .where(
              "notificationsAllowed",
              "==",
              true,
          )
          .get();

  const messages = [];

  for (const deviceDocument of
    devicesSnapshot.docs) {
    const device =
        deviceDocument.data();

    const fcmToken =
        typeof device.fcmToken ===
        "string" ?
          device.fcmToken.trim() :
          "";

    if (!fcmToken) {
      continue;
    }

    messages.push({
      notification: {
        title: notificationTitle,
        body:
            `${cameraName} • ` +
            "sprawdź, co się dzieje",
      },

      data: {
        type: "camera_event",
        eventId,
        cameraId,
        cameraEventType: eventType,
      },

      android: {
        priority: "high",

        notification: {
          tag:
              `camera_event_${eventId}`,
        },
      },

      token: fcmToken,
    });
  }

  if (messages.length === 0) {
    console.log(
        "CAMERA PUSH: " +
        "brak urządzeń właściciela",
    );

    return;
  }

  for (let index = 0;
    index < messages.length;
    index += 500) {
    const batch =
        messages.slice(
            index,
            index + 500,
        );

    const result =
        await getMessaging()
            .sendEach(batch);

    console.log(
        "CAMERA PUSH: wysłano =",
        result.successCount,
    );

    console.log(
        "CAMERA PUSH: błędy =",
        result.failureCount,
    );

    result.responses.forEach(
        (item, responseIndex) => {
          if (item.success) {
            return;
          }

          console.error(
              "CAMERA PUSH ERROR:",
              batch[responseIndex]
                  .token,
              item.error,
          );
        },
    );
  }
}
/**
 * Przyjmuje i agreguje zdarzenie kamery.
 *
 * @param {Object} input Dane zdarzenia.
 * @return {Promise<Object>} Wynik przetwarzania.
 */
async function ingestCameraEventInternal(
    input,
) {
  const ownerId =
      typeof input.ownerId === "string" ?
        input.ownerId.trim() :
        "";

  const cameraId =
      typeof input.cameraId === "string" ?
        input.cameraId.trim() :
        "";

  if (!ownerId) {
    throw new HttpsError(
        "invalid-argument",
        "Brak ownerId.",
    );
  }

  if (!cameraId) {
    throw new HttpsError(
        "invalid-argument",
        "Brak cameraId.",
    );
  }

  const type =
      normalizeCameraEventType(
          input.type,
      );

  const source =
      normalizeCameraEventSource(
          input.source,
      );

  const confidence =
      normalizeConfidence(
          input.confidence,
      );

  const snapshotUrl =
      normalizeOptionalUrl(
          input.snapshotUrl,
      );

  const clipUrl =
      normalizeOptionalUrl(
          input.clipUrl,
      );

  const nowMillis =
      Date.now();

  const occurredAtMillis =
      normalizeOccurredAt(
          input.occurredAt,
          nowMillis,
      );

  const cameraRef =
      db.collection("users")
          .doc(ownerId)
          .collection("cameras")
          .doc(cameraId);

  const eventsCollection =
      db.collection("cameraEvents");

  const canMerge =
      isDetectionCameraEvent(type);

  const stateId =
      `${ownerId}_${cameraId}_detection`;

  const stateRef =
      db.collection("cameraEventStates")
          .doc(stateId);

  const result =
    await db.runTransaction(
        async (transaction) => {
          const cameraSnapshot =
            await transaction.get(
                cameraRef,
            );

          if (!cameraSnapshot.exists) {
            throw new HttpsError(
                "not-found",
                "Nie znaleziono kamery.",
            );
          }

          const cameraData =
            cameraSnapshot.data();

          const cameraName =
            typeof cameraData.name ===
                "string" &&
            cameraData.name.trim() ?
            cameraData.name.trim() :
            "Kamera";

          let stateSnapshot = null;
          let activeEventSnapshot = null;

          if (canMerge) {
            stateSnapshot =
              await transaction.get(
                  stateRef,
              );

            if (stateSnapshot.exists) {
              const state =
                stateSnapshot.data();

              const activeEventId =
                typeof state.activeEventId ===
                "string" ?
                  state.activeEventId :
                  "";

              if (activeEventId) {
                activeEventSnapshot =
                  await transaction.get(
                      eventsCollection
                          .doc(activeEventId),
                  );
              }
            }
          }

          const nowTimestamp =
            Timestamp.fromMillis(
                nowMillis,
            );

          const occurredAtTimestamp =
            Timestamp.fromMillis(
                occurredAtMillis,
            );

          if (canMerge &&
            stateSnapshot !== null &&
            stateSnapshot.exists &&
            activeEventSnapshot !== null &&
            activeEventSnapshot.exists) {
            const state =
              stateSnapshot.data();

            const lastReceivedAt =
              state.lastReceivedAt;

            const lastReceivedMillis =
              lastReceivedAt instanceof
              Timestamp ?
                lastReceivedAt.toMillis() :
                0;

            const withinWindow =
              nowMillis -
              lastReceivedMillis <=
              cameraEventMergeWindowMs;

            const activeEvent =
              activeEventSnapshot.data();

            const currentStatus =
              typeof activeEvent.status ===
              "string" ?
                activeEvent.status :
                "new";

            const canUpdateEvent =
              currentStatus === "new" ||
              currentStatus === "viewed";

            if (withinWindow &&
              canUpdateEvent) {
              const currentType =
                typeof activeEvent.type ===
                "string" ?
                  activeEvent.type :
                  "motion";

              const mergedType =
                selectCameraEventType(
                    currentType,
                    type,
                );

              const currentCount =
                typeof activeEvent
                    .occurrenceCount ===
                "number" ?
                  activeEvent
                      .occurrenceCount :
                  1;

              const eventRef =
                activeEventSnapshot.ref;

              transaction.update(
                  eventRef,
                  {
                    type: mergedType,
                    lastOccurredAt:
                      occurredAtTimestamp,
                    occurrenceCount:
                      currentCount + 1,
                    source:
                      activeEvent.source ===
                      source ?
                        source :
                        "multiple",
                    confidence:
                      mergeConfidence(
                          activeEvent
                              .confidence,
                          confidence,
                      ),
                    snapshotUrl:
                      snapshotUrl ||
                      activeEvent
                          .snapshotUrl ||
                      null,
                    clipUrl:
                      clipUrl ||
                      activeEvent
                          .clipUrl ||
                      null,
                    updatedAt:
                      nowTimestamp,
                  },
              );

              transaction.set(
                  stateRef,
                  {
                    activeEventId:
                      eventRef.id,
                    lastReceivedAt:
                      nowTimestamp,
                  },
                  {
                    merge: true,
                  },
              );

              return {
                eventId: eventRef.id,
                merged: true,
                type: mergedType,
                occurrenceCount:
                    currentCount + 1,
                cameraName,
              };
            }
          }

          const eventRef =
            eventsCollection.doc();

          const eventData = {
            cameraId,
            ownerId,
            type,
            status: "new",
            occurredAt:
              occurredAtTimestamp,
            lastOccurredAt:
              occurredAtTimestamp,
            occurrenceCount: 1,
            source,
            confidence,
            snapshotUrl,
            clipUrl,
            incidentId: null,
            createdAt:
              nowTimestamp,
            updatedAt:
              nowTimestamp,
          };

          transaction.set(
              eventRef,
              eventData,
          );

          if (canMerge) {
            transaction.set(
                stateRef,
                {
                  activeEventId:
                    eventRef.id,
                  lastReceivedAt:
                    nowTimestamp,
                },
                {
                  merge: true,
                },
            );
          }

          return {
            eventId: eventRef.id,
            merged: false,
            type,
            occurrenceCount: 1,
            cameraName,
          };
        },
    );
  if (!result.merged) {
    try {
      await sendCameraEventNotification({
        ownerId,
        cameraId,
        cameraName:
    result.cameraName,
        eventId:
    result.eventId,
        eventType:
    result.type,
      });
    } catch (error) {
      console.error(
          "CAMERA PUSH: " +
        "nie udało się wysłać",
          error,
      );
    }
  }

  return result;
}

/**
 * TYLKO DEVELOPMENT.
 *
 * Pozwala naszej fake kamerze
 * na komputerze wysłać event do
 * lokalnego Functions Emulator.
 *
 * Funkcja odrzuca każde żądanie poza
 * Firebase Emulator Suite.
 */

/**
 * Przyjmuje zdarzenie kamery od
 * zalogowanej aplikacji SafeHood.
 *
 * ownerId NIE pochodzi od klienta.
 * Bierzemy go wyłącznie z Firebase Auth.
 */

/**
 * Tworzy jednorazowy kod parowania
 * dla zalogowanego użytkownika.
 */
/**
 * Przypisuje kamery użytkownika do
 * wybranego, sparowanego Bridge’a.
 */
/**
 * Usuwa Bridge należący do użytkownika.
 *
 * Najpierw unieważnia jego sekret, następnie
 * odpina kamery, a na końcu usuwa dokument.
 */
exports.removeBridge = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const ownerId =
          request.auth.uid;

      const data =
          request.data || {};

      const bridgeId =
          typeof data.bridgeId === "string" ?
            data.bridgeId.trim() :
            "";

      if (!bridgeId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora Bridge.",
        );
      }

      const userRef =
          db
              .collection("users")
              .doc(ownerId);

      const bridgeRef =
          userRef
              .collection("bridges")
              .doc(bridgeId);

      const credentialsRef =
          db
              .collection("bridgeCredentials")
              .doc(bridgeId);

      const camerasQuery =
          userRef
              .collection("cameras")
              .where(
                  "bridgeId",
                  "==",
                  bridgeId,
              );

      const [
        userSnapshot,
        bridgeSnapshot,
        credentialsSnapshot,
        camerasSnapshot,
      ] = await Promise.all([
        userRef.get(),
        bridgeRef.get(),
        credentialsRef.get(),
        camerasQuery.get(),
      ]);

      if (!bridgeSnapshot.exists) {
        throw new HttpsError(
            "not-found",
            "Nie znaleziono Bridge.",
        );
      }

      if (credentialsSnapshot.exists) {
        const credentials =
            credentialsSnapshot.data();

        if (
          credentials.ownerId !==
          ownerId
        ) {
          throw new HttpsError(
              "permission-denied",
              "Bridge nie należy do użytkownika.",
          );
        }

        await credentialsRef.update({
          status:
              "revoked",
          secretHash:
              FieldValue.delete(),
          revokedAt:
              Timestamp.now(),
          updatedAt:
              Timestamp.now(),
        });
      }

      const timestamp =
          Timestamp.now();

      const batchSize = 400;

      for (
        let start = 0;
        start < camerasSnapshot.docs.length;
        start += batchSize
      ) {
        const batch =
            db.batch();

        const documents =
            camerasSnapshot.docs.slice(
                start,
                start + batchSize,
            );

        for (const document of documents) {
          batch.update(
              document.ref,
              {
                bridgeId:
                    FieldValue.delete(),
                bridgeAssignedAt:
                    FieldValue.delete(),
                bridgeMonitoringStatus:
                    "offline",
                bridgeMonitoringUpdatedAt:
                    timestamp,
                updatedAt:
                    timestamp,
              },
          );
        }

        await batch.commit();
      }

      const userData =
          userSnapshot.data() || {};

      const bridgeData =
          bridgeSnapshot.data() || {};

      const wasActive =
          userData.activeBridgeId ===
            bridgeId ||
          bridgeData.isActive ===
            true;

      if (wasActive) {
        await userRef.set(
            {
              activeBridgeId:
                  FieldValue.delete(),
              activeBridgeUpdatedAt:
                  timestamp,
            },
            {
              merge: true,
            },
        );
      }

      await bridgeRef.delete();

      console.log(
          "BRIDGE REMOVED:",
          {
            ownerId,
            bridgeId,
            removedCameraCount:
                camerasSnapshot.docs.length,
            credentialsRevoked:
                credentialsSnapshot.exists,
            wasActive,
          },
      );

      return {
        bridgeId,
        removedCameraCount:
            camerasSnapshot.docs.length,
        credentialsRevoked:
            credentialsSnapshot.exists,
        wasActive,
      };
    },
);
exports.assignCamerasToBridge = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const ownerId =
          request.auth.uid;

      const data =
          request.data || {};

      const bridgeId =
          typeof data.bridgeId === "string" ?
            data.bridgeId.trim() :
            "";

      if (!bridgeId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora Bridge.",
        );
      }

      const bridgeRef =
          db
              .collection("users")
              .doc(ownerId)
              .collection("bridges")
              .doc(bridgeId);

      const credentialsRef =
          db
              .collection(
                  "bridgeCredentials",
              )
              .doc(bridgeId);

      const [
        bridgeSnapshot,
        credentialsSnapshot,
      ] = await Promise.all([
        bridgeRef.get(),
        credentialsRef.get(),
      ]);

      if (!bridgeSnapshot.exists) {
        throw new HttpsError(
            "not-found",
            "Nie znaleziono Bridge.",
        );
      }

      if (!credentialsSnapshot.exists) {
        throw new HttpsError(
            "failed-precondition",
            "Bridge nie jest poprawnie sparowany.",
        );
      }

      const credentials =
          credentialsSnapshot.data();

      if (
        credentials.ownerId !== ownerId ||
        credentials.status !== "active"
      ) {
        throw new HttpsError(
            "permission-denied",
            "Bridge nie należy do użytkownika.",
        );
      }

      const [
        camerasSnapshot,
        bridgesSnapshot,
      ] = await Promise.all([
        db
            .collection("users")
            .doc(ownerId)
            .collection("cameras")
            .get(),

        db
            .collection("users")
            .doc(ownerId)
            .collection("bridges")
            .get(),
      ]);

      const onvifCameras =
          camerasSnapshot.docs.filter(
              (document) => {
                return (
                  document.data()
                      .connectionType ===
                    "onvif"
                );
              },
          );

      const timestamp =
          Timestamp.now();

      const batchSize = 400;

      for (
        let start = 0;
        start < onvifCameras.length;
        start += batchSize
      ) {
        const batch =
            db.batch();

        const documents =
            onvifCameras.slice(
                start,
                start + batchSize,
            );

        for (const document of documents) {
          const camera =
              document.data();

          batch.update(
              document.ref,
              {
                monitoringMode:
                    "bridge",
                bridgeId,
                bridgeAssignedAt:
                    timestamp,
                bridgeMonitoringStatus:
                    camera
                        .motionDetectionEnabled ===
                      false ?
                      "offline" :
                      "connecting",
                bridgeMonitoringUpdatedAt:
                    timestamp,
                updatedAt:
                    timestamp,
              },
          );
        }

        await batch.commit();
      }
      const bridgeSelectionBatch =
    db.batch();

      bridgeSelectionBatch.set(
          db
              .collection("users")
              .doc(ownerId),
          {
            activeBridgeId:
          bridgeId,
            activeBridgeUpdatedAt:
          timestamp,
          },
          {
            merge: true,
          },
      );

      for (
        const bridgeDocument of
        bridgesSnapshot.docs
      ) {
        bridgeSelectionBatch.update(
            bridgeDocument.ref,
            {
              isActive:
            bridgeDocument.id ===
            bridgeId,
              updatedAt:
            timestamp,
            },
        );
      }

      await bridgeSelectionBatch.commit();
      console.log(
          "BRIDGE CAMERAS ASSIGNED:",
          {
            ownerId,
            bridgeId,
            cameraCount:
                onvifCameras.length,
          },
      );

      return {
        bridgeId,
        assignedCameraCount:
            onvifCameras.length,
      };
    },
);
exports.createBridgePairingCode = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const ownerId =
          request.auth.uid;

      const code =
          generateBridgePairingCode();

      const codeHash =
          hashBridgeValue(code);

      const createdAt =
          Timestamp.now();

      const expiresAt =
          Timestamp.fromMillis(
              createdAt.toMillis() +
              bridgePairingLifetimeMs,
          );

      const pairingRef =
          db
              .collection(
                  "bridgePairingCodes",
              )
              .doc(codeHash);

      await pairingRef.create({
        ownerId,
        status: "pending",
        createdAt,
        updatedAt: createdAt,
        expiresAt,
      });

      console.log(
          "BRIDGE PAIRING CODE CREATED:",
          {
            ownerId,
            expiresAt:
                expiresAt.toDate()
                    .toISOString(),
          },
      );

      return {
        code:
            formatBridgePairingCode(
                code,
            ),
        expiresAt:
            expiresAt.toMillis(),
      };
    },
);

/**
 * Pozwala urządzeniu Bridge odebrać
 * jednorazowy kod parowania.
 */
exports.claimBridgePairing = onRequest(
    {
      region: "europe-central2",
    },
    async (request, response) => {
      if (request.method !== "POST") {
        response.status(405).json({
          error: "POST required.",
        });

        return;
      }

      const body =
          request.body || {};

      const code =
          normalizeBridgePairingCode(
              body.code,
          );

      if (code.length !== 8) {
        response.status(400).json({
          error:
              "Nieprawidłowy lub wygasły kod.",
        });

        return;
      }

      const bridgeName =
          typeof body.name === "string" &&
          body.name.trim() ?
            body.name.trim().substring(0, 80) :
            "SafeHood Bridge";

      const platform =
          typeof body.platform === "string" &&
          body.platform.trim() ?
            body.platform.trim().substring(0, 40) :
            "unknown";

      const version =
          typeof body.version === "string" &&
          body.version.trim() ?
            body.version.trim().substring(0, 40) :
            "1.0.0";

      const codeHash =
          hashBridgeValue(code);

      const bridgeSecret =
          randomBytes(32)
              .toString("base64url");

      const secretHash =
          hashBridgeValue(
              bridgeSecret,
          );

      const pairingRef =
          db
              .collection(
                  "bridgePairingCodes",
              )
              .doc(codeHash);

      try {
        const result =
            await db.runTransaction(
                async (transaction) => {
                  const pairingSnapshot =
                      await transaction.get(
                          pairingRef,
                      );

                  if (!pairingSnapshot.exists) {
                    throw new Error(
                        "invalid-pairing-code",
                    );
                  }

                  const pairing =
                      pairingSnapshot.data();

                  const expiresAt =
                      pairing.expiresAt;

                  if (
                    pairing.status !== "pending" ||
                    !(expiresAt instanceof Timestamp) ||
                    expiresAt.toMillis() <=
                      Date.now()
                  ) {
                    throw new Error(
                        "invalid-pairing-code",
                    );
                  }

                  const ownerId =
                      typeof pairing.ownerId ===
                      "string" ?
                        pairing.ownerId :
                        "";

                  if (!ownerId) {
                    throw new Error(
                        "invalid-pairing-code",
                    );
                  }

                  const bridgeRef =
                      db
                          .collection("users")
                          .doc(ownerId)
                          .collection("bridges")
                          .doc();

                  const credentialsRef =
                      db
                          .collection(
                              "bridgeCredentials",
                          )
                          .doc(bridgeRef.id);

                  const timestamp =
                      Timestamp.now();

                  transaction.set(
                      bridgeRef,
                      {
                        bridgeId:
                            bridgeRef.id,
                        ownerId,
                        name:
                            bridgeName,
                        status:
                            "offline",
                        platform,
                        version,
                        activeCameraCount:
    0,
                        isActive:
    false,
                        capabilities: [
                          "onvif-events",
                        ],
                        pairedAt:
                            timestamp,
                        updatedAt:
                            timestamp,
                        lastSeenAt:
                            null,
                      },
                  );

                  transaction.set(
                      credentialsRef,
                      {
                        bridgeId:
                            bridgeRef.id,
                        ownerId,
                        secretHash,
                        status:
                            "active",
                        createdAt:
                            timestamp,
                        updatedAt:
                            timestamp,
                      },
                  );

                  transaction.update(
                      pairingRef,
                      {
                        status:
                            "claimed",
                        bridgeId:
                            bridgeRef.id,
                        claimedAt:
                            timestamp,
                        updatedAt:
                            timestamp,
                      },
                  );

                  return {
                    bridgeId:
                        bridgeRef.id,
                  };
                },
            );

        console.log(
            "BRIDGE PAIRED:",
            {
              bridgeId:
                  result.bridgeId,
              platform,
            },
        );

        response.status(200).json({
          ok: true,
          bridgeId:
              result.bridgeId,
          bridgeSecret,
        });
      } catch (error) {
        if (
          error instanceof Error &&
          error.message ===
            "invalid-pairing-code"
        ) {
          response.status(400).json({
            error:
                "Nieprawidłowy lub wygasły kod.",
          });

          return;
        }

        console.error(
            "BRIDGE PAIRING ERROR:",
            error,
        );

        response.status(500).json({
          error:
              "Nie udało się sparować Bridge.",
        });
      }
    },
);
/**
 * Zwraca konfigurację kamer przypisanych
 * do uwierzytelnionego Bridge’a.
 */
exports.getBridgeConfiguration = onRequest(
    {
      region: "europe-central2",
    },
    async (request, response) => {
      if (request.method !== "POST") {
        response.status(405).json({
          error: "POST required.",
        });

        return;
      }

      try {
        const bridgeIdentity =
            await authenticateBridgeRequest(
                request,
            );

        if (!bridgeIdentity) {
          response.status(401).json({
            error:
                "Nieprawidłowe dane Bridge.",
          });

          return;
        }

        const snapshot =
            await db
                .collection("users")
                .doc(
                    bridgeIdentity.ownerId,
                )
                .collection("cameras")
                .get();

        const cameras = [];

        for (
          const document of
          snapshot.docs
        ) {
          const camera =
              document.data();

          if (
            camera.connectionType !==
              "onvif" ||
            camera.motionDetectionEnabled ===
              false ||
            (
              camera.monitoringMode &&
              camera.monitoringMode !==
                "bridge"
            ) ||
            camera.bridgeId !==
              bridgeIdentity.bridgeId
          ) {
            continue;
          }

          cameras.push({
            id:
                document.id,

            name:
                typeof camera.name ===
                "string" ?
                  camera.name :
                  "",

            brand:
    typeof camera.brand ===
      "string" ?
        camera.brand :
        "",

            model:
    typeof camera.model ===
      "string" ?
        camera.model :
        "",

            discoverySources:
    Array.isArray(
        camera.discoverySources,
    ) ?
      camera.discoverySources :
      [],

            locationName:
                typeof camera.locationName ===
                "string" ?
                  camera.locationName :
                  "",

            ipAddress:
                typeof camera.ipAddress ===
                "string" ?
                  camera.ipAddress :
                  null,

            onvifServiceUrl:
                typeof camera.onvifServiceUrl ===
                "string" ?
                  camera.onvifServiceUrl :
                  null,

            openPorts:
                Array.isArray(
                    camera.openPorts,
                ) ?
                  camera.openPorts :
                  [],

            connectionType:
                "onvif",

            monitoringMode:
                "bridge",

            bridgeId:
                bridgeIdentity.bridgeId,

            motionDetectionEnabled:
                true,
          });
        }

        response.status(200).json({
          ok: true,
          bridgeId:
              bridgeIdentity.bridgeId,
          cameraCount:
              cameras.length,
          cameras,
        });
      } catch (error) {
        console.error(
            "BRIDGE CONFIGURATION ERROR:",
            error,
        );

        response.status(500).json({
          error:
              "Nie udało się pobrać konfiguracji.",
        });
      }
    },
);
/**
 * Aktualizuje heartbeat Bridge’a oraz
 * stany przypisanych kamer.
 */
exports.reportBridgeState = onRequest(
    {
      region: "europe-central2",
    },
    async (request, response) => {
      if (request.method !== "POST") {
        response.status(405).json({
          error: "POST required.",
        });

        return;
      }

      try {
        const bridgeIdentity =
            await authenticateBridgeRequest(
                request,
            );

        if (!bridgeIdentity) {
          response.status(401).json({
            error:
                "Nieprawidłowe dane Bridge.",
          });

          return;
        }

        const body =
            request.body || {};

        const bridgeStatus =
            body.status === "offline" ?
              "offline" :
              "online";

        const receivedStatuses =
            Array.isArray(
                body.cameraStatuses,
            ) ?
              body.cameraStatuses
                  .slice(0, 100) :
              [];

        const normalizedStatuses =
            new Map();

        for (
          const receivedStatus of
          receivedStatuses
        ) {
          if (
            !receivedStatus ||
            typeof receivedStatus !==
              "object"
          ) {
            continue;
          }

          const cameraId =
              typeof receivedStatus.cameraId ===
                "string" ?
                receivedStatus.cameraId.trim() :
                "";

          const status =
              typeof receivedStatus.status ===
                "string" ?
                receivedStatus.status.trim() :
                "";

          if (
            !cameraId ||
            !allowedBridgeMonitoringStatuses
                .has(status)
          ) {
            continue;
          }

          normalizedStatuses.set(
              cameraId,
              status,
          );
        }

        const statusEntries = [
          ...normalizedStatuses.entries(),
        ];

        const cameraRefs =
            statusEntries.map(
                ([cameraId]) => {
                  return db
                      .collection("users")
                      .doc(
                          bridgeIdentity.ownerId,
                      )
                      .collection("cameras")
                      .doc(cameraId);
                },
            );

        const cameraSnapshots =
            cameraRefs.length > 0 ?
              await db.getAll(
                  ...cameraRefs,
              ) :
              [];

        const timestamp =
            Timestamp.now();

        const batch =
            db.batch();

        let activeCameraCount = 0;
        let acceptedCameraCount = 0;

        for (
          let index = 0;
          index < cameraSnapshots.length;
          index += 1
        ) {
          const cameraSnapshot =
              cameraSnapshots[index];

          if (!cameraSnapshot.exists) {
            continue;
          }

          const camera =
              cameraSnapshot.data();

          if (
            camera.bridgeId !==
              bridgeIdentity.bridgeId
          ) {
            continue;
          }

          const receivedStatus =
              statusEntries[index][1];

          const cameraStatus =
              bridgeStatus === "offline" ?
                "offline" :
                receivedStatus;

          if (cameraStatus === "online") {
            activeCameraCount += 1;
          }

          acceptedCameraCount += 1;

          batch.update(
              cameraSnapshot.ref,
              {
                bridgeMonitoringStatus:
                    cameraStatus,
                bridgeMonitoringUpdatedAt:
                    timestamp,
              },
          );
        }

        const bridgeRef =
            db
                .collection("users")
                .doc(
                    bridgeIdentity.ownerId,
                )
                .collection("bridges")
                .doc(
                    bridgeIdentity.bridgeId,
                );

        batch.set(
            bridgeRef,
            {
              bridgeId:
                  bridgeIdentity.bridgeId,
              ownerId:
                  bridgeIdentity.ownerId,
              status:
                  bridgeStatus,
              activeCameraCount:
                  bridgeStatus === "online" ?
                    activeCameraCount :
                    0,
              lastSeenAt:
                  timestamp,
              updatedAt:
                  timestamp,
            },
            {
              merge: true,
            },
        );

        await batch.commit();

        response.status(200).json({
          ok: true,
          bridgeId:
              bridgeIdentity.bridgeId,
          status:
              bridgeStatus,
          activeCameraCount:
              bridgeStatus === "online" ?
                activeCameraCount :
                0,
          acceptedCameraCount,
        });
      } catch (error) {
        console.error(
            "BRIDGE STATE ERROR:",
            error,
        );

        response.status(500).json({
          error:
              "Nie udało się zapisać stanu Bridge.",
        });
      }
    },
);
/**
 * Przyjmuje zdarzenie wyłącznie od
 * uwierzytelnionego Bridge’a.
 */
exports.ingestBridgeCameraEvent =
    onRequest(
        {
          region: "europe-central2",
        },
        async (request, response) => {
          if (request.method !== "POST") {
            response.status(405).json({
              error:
                  "POST required.",
            });

            return;
          }

          try {
            const bridgeIdentity =
                await authenticateBridgeRequest(
                    request,
                );

            if (!bridgeIdentity) {
              response.status(401).json({
                error:
                    "Nieprawidłowe dane Bridge.",
              });

              return;
            }

            const data =
                request.body || {};

            const cameraId =
                typeof data.cameraId ===
                  "string" ?
                  data.cameraId.trim() :
                  "";

            if (!cameraId) {
              response.status(400).json({
                error:
                    "Brak identyfikatora kamery.",
              });

              return;
            }

            const cameraSnapshot =
                await db
                    .collection("users")
                    .doc(
                        bridgeIdentity.ownerId,
                    )
                    .collection("cameras")
                    .doc(cameraId)
                    .get();

            if (!cameraSnapshot.exists) {
              response.status(404).json({
                error:
                    "Nie znaleziono kamery.",
              });

              return;
            }

            const camera =
                cameraSnapshot.data();

            if (
              camera.bridgeId !==
                bridgeIdentity.bridgeId ||
              camera.connectionType !==
                "onvif"
            ) {
              response.status(403).json({
                error:
                    "Kamera nie jest przypisana " +
                    "do tego Bridge.",
              });

              return;
            }

            if (
              camera.motionDetectionEnabled ===
                false
            ) {
              response.status(409).json({
                error:
                    "Monitoring kamery jest " +
                    "wyłączony.",
              });

              return;
            }

            const result =
                await ingestCameraEventInternal({
                  ownerId:
                      bridgeIdentity.ownerId,
                  cameraId,
                  type:
                      data.type,
                  source:
                      data.source,
                  confidence:
                      data.confidence,
                  snapshotUrl:
                      data.snapshotUrl,
                  clipUrl:
                      data.clipUrl,
                  occurredAt:
                      data.occurredAt,
                });

            console.log(
                "BRIDGE CAMERA EVENT:",
                {
                  bridgeId:
                      bridgeIdentity.bridgeId,
                  cameraId,
                  eventId:
                      result.eventId,
                  type:
                      result.type,
                  merged:
                      result.merged,
                },
            );

            response.status(200).json({
              ok: true,
              id:
                  result.eventId,
              eventId:
                  result.eventId,
              type:
                  result.type,
              merged:
                  result.merged,
              occurrenceCount:
                  result.occurrenceCount,
            });
          } catch (error) {
            console.error(
                "BRIDGE CAMERA EVENT ERROR:",
                error,
            );

            const code =
                error &&
                typeof error.code ===
                  "string" ?
                  error.code :
                  "";

            let status = 500;

            if (code === "invalid-argument") {
              status = 400;
            }

            if (code === "not-found") {
              status = 404;
            }

            response.status(status).json({
              error:
                  error &&
                  typeof error.message ===
                    "string" ?
                    error.message :
                    "Nie udało się zapisać " +
                    "zdarzenia.",
            });
          }
        },
    );
exports.ingestCameraEvent = onCall(
    {
      region: "europe-central2",
    },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError(
            "unauthenticated",
            "Musisz być zalogowany.",
        );
      }

      const uid =
          request.auth.uid;

      const data =
          request.data || {};

      const cameraId =
          typeof data.cameraId === "string" ?
            data.cameraId.trim() :
            "";

      if (!cameraId) {
        throw new HttpsError(
            "invalid-argument",
            "Brak identyfikatora kamery.",
        );
      }

      const result =
          await ingestCameraEventInternal({
            ownerId: uid,
            cameraId,
            type: data.type,
            source: data.source,
            confidence: data.confidence,
            snapshotUrl:
                data.snapshotUrl,
            clipUrl:
                data.clipUrl,
            occurredAt:
                data.occurredAt,
          });

      console.log(
          "CAMERA EVENT AUTH:",
          {
            uid,
            cameraId,
            eventId:
                result.eventId,
            type:
                result.type,
            merged:
                result.merged,
          },
      );

      return {
        id: result.eventId,
        type: result.type,
        merged: result.merged,
        occurrenceCount:
            result.occurrenceCount,
      };
    },
);
/**
 * Normalizuje nazwę dostawcy chmury.
 *
 * @param {*} value Surowa wartość.
 * @return {string} Kanoniczna nazwa.
 */
function normalizeManufacturerCloudProvider(
    value,
) {
  const normalized =
      typeof value === "string" ?
        value.trim().toLowerCase() :
        "";

  if (normalized === "safeark") {
    return "safeArk";
  }

  throw new HttpsError(
      "invalid-argument",
      "Nieobsługiwany dostawca chmury.",
  );
}

/**
 * Normalizuje identyfikator urządzenia
 * nadany przez producenta.
 *
 * @param {*} value Surowa wartość.
 * @return {string} Identyfikator urządzenia.
 */
function normalizeCloudDeviceId(value) {
  const normalized =
      typeof value === "string" ?
        value.trim() :
        "";

  if (
    !normalized ||
    normalized.length > 256
  ) {
    throw new HttpsError(
        "invalid-argument",
        "Nieprawidłowy cloudDeviceId.",
    );
  }

  return normalized;
}

/**
 * Znajduje kamerę SafeHood na podstawie
 * tożsamości urządzenia w chmurze.
 *
 * ownerId i cameraId nie pochodzą
 * z zewnętrznego żądania.
 *
 * @param {Object} input Dane urządzenia.
 * @param {string} input.provider Dostawca.
 * @param {string} input.cloudDeviceId ID urządzenia.
 * @return {Promise<Object>} Tożsamość kamery.
 */
async function resolveManufacturerCloudCamera({
  provider,
  cloudDeviceId,
}) {
  const snapshot =
      await db
          .collectionGroup("cameras")
          .where(
              "cloudDeviceId",
              "==",
              cloudDeviceId,
          )
          .get();

  const matches =
      snapshot.docs.filter(
          (document) => {
            const camera =
                document.data();

            return (
              camera.connectionType ===
                "manufacturerCloud" &&
              camera.monitoringMode ===
                "cloud" &&
              camera.cloudProvider ===
                provider
            );
          },
      );

  if (matches.length === 0) {
    throw new HttpsError(
        "not-found",
        "Nie znaleziono kamery chmurowej.",
    );
  }

  if (matches.length > 1) {
    throw new HttpsError(
        "failed-precondition",
        "Identyfikator urządzenia nie jest unikalny.",
    );
  }

  const cameraDocument =
      matches[0];

  const ownerReference =
      cameraDocument.ref.parent.parent;

  if (ownerReference == null) {
    throw new HttpsError(
        "internal",
        "Nie udało się ustalić właściciela kamery.",
    );
  }

  return {
    ownerId: ownerReference.id,
    cameraId: cameraDocument.id,
  };
}

/**
 * TYLKO DEVELOPMENT.
 *
 * Symuluje webhook producenta kamery.
 * Żądanie przekazuje wyłącznie provider
 * i cloudDeviceId. Backend sam odnajduje
 * właściciela oraz dokument kamery.
 */
exports.devIngestManufacturerCameraEvent =
    onRequest(
        {
          region: "europe-central2",
        },
        async (request, response) => {
          if (
            process.env.FUNCTIONS_EMULATOR !==
            "true"
          ) {
            response.status(404).json({
              error: "Not found.",
            });

            return;
          }

          if (request.method !== "POST") {
            response.status(405).json({
              error: "POST required.",
            });

            return;
          }

          const expectedSecret =
              process.env
                  .SAFEHOOD_DEV_EVENT_SECRET ||
              "";

          const receivedSecret =
              typeof request.headers[
                  "x-safehood-dev-secret"
              ] === "string" ?
                request.headers[
                    "x-safehood-dev-secret"
                ] :
                "";

          if (
            !expectedSecret ||
            receivedSecret !== expectedSecret
          ) {
            response.status(401).json({
              error:
                  "Invalid development secret.",
            });

            return;
          }

          try {
            const data =
                request.body || {};

            const provider =
                normalizeManufacturerCloudProvider(
                    data.provider,
                );

            const cloudDeviceId =
                normalizeCloudDeviceId(
                    data.cloudDeviceId,
                );

            const result =
                await runManufacturerEventOnce({
                  db,
                  Timestamp,
                  HttpsError,
                  provider,
                  cloudDeviceId,
                  externalEventId:
                      data.externalEventId,
                  handler: async () => {
                    const camera =
                        await resolveManufacturerCloudCamera({
                          provider,
                          cloudDeviceId,
                        });

                    const eventResult =
                        await ingestCameraEventInternal({
                          ownerId:
                              camera.ownerId,
                          cameraId:
                              camera.cameraId,
                          type:
                              data.type,
                          source:
                              provider,
                          confidence:
                              data.confidence,
                          snapshotUrl:
                              data.snapshotUrl,
                          clipUrl:
                              data.clipUrl,
                          occurredAt:
                              data.occurredAt,
                        });

                    return {
                      ...eventResult,
                      cameraId:
                          camera.cameraId,
                    };
                  },
                });

            console.log(
                "MANUFACTURER CAMERA EVENT:",
                {
                  provider,
                  cloudDeviceId,
                  externalEventId:
                      result.externalEventId,
                  cameraId:
                      result.cameraId,
                  eventId:
                      result.eventId,
                  merged:
                      result.merged,
                  duplicate:
                      result.duplicate,
                },
            );

            response.status(200).json({
              ok: true,
              provider,
              cloudDeviceId,
              ...result,
            });
          } catch (error) {
            console.error(
                "MANUFACTURER CAMERA EVENT ERROR:",
                error,
            );

            const code =
                error &&
                typeof error.code ===
                    "string" ?
                  error.code :
                  "";

            let status = 500;

            if (code === "invalid-argument") {
              status = 400;
            }

            if (code === "not-found") {
              status = 404;
            }

            if (
              code === "failed-precondition" ||
              code === "aborted"
            ) {
              status = 409;
            }

            response.status(status).json({
              error:
                  error &&
                  typeof error.message ===
                      "string" ?
                    error.message :
                    "Nie udało się zapisać zdarzenia.",
            });
          }
        },
    );
exports.devIngestCameraEvent = onRequest(
    {
      region: "europe-central2",
    },
    async (request, response) => {
      if (process.env.FUNCTIONS_EMULATOR !==
          "true") {
        response.status(404).json({
          error: "Not found.",
        });

        return;
      }

      if (request.method !== "POST") {
        response.status(405).json({
          error: "POST required.",
        });

        return;
      }

      const expectedSecret =
          process.env
              .SAFEHOOD_DEV_EVENT_SECRET ||
          "";

      const receivedSecret =
          typeof request.headers[
              "x-safehood-dev-secret"
          ] === "string" ?
            request.headers[
                "x-safehood-dev-secret"
            ] :
            "";

      if (!expectedSecret ||
          receivedSecret !==
          expectedSecret) {
        response.status(401).json({
          error:
              "Invalid development secret.",
        });

        return;
      }

      try {
        const result =
            await ingestCameraEventInternal(
                request.body || {},
            );

        console.log(
            "CAMERA EVENT:",
            result,
        );

        response.status(200).json({
          ok: true,
          ...result,
        });
      } catch (error) {
        console.error(
            "CAMERA EVENT ERROR:",
            error,
        );

        const code =
            error &&
            typeof error.code === "string" ?
              error.code :
              "";

        let status = 500;

        if (code === "invalid-argument") {
          status = 400;
        }

        if (code === "not-found") {
          status = 404;
        }

        response.status(status).json({
          error:
              error &&
              typeof error.message ===
              "string" ?
                error.message :
                "Nie udało się zapisać eventu.",
        });
      }
    },
);
