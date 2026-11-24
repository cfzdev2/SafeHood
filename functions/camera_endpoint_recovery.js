"use strict";

/**
 * Save a rediscovered endpoint only for the same, already assigned device.
 * @param {Object} dependencies Firestore and receiver authentication.
 * @return {Function} HTTP handler.
 */
function createCameraEndpointRecoveryHandler({db, Timestamp, authenticate}) {
  return async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).json({error: "POST required."});
      return;
    }
    const uuid = new RegExp("^(?:urn:)?(?:uuid:)?" +
      "([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$", "i");
    const identity = (value) => typeof value === "string" ?
      uuid.exec(value.trim())?.[1]?.toLowerCase() : null;
    try {
      const receiver = await authenticate(request);
      if (!receiver) {
        response.status(401).json({error: "Brak dostępu."});
        return;
      }
      const data = request.body || {};
      if (typeof data.cameraId !== "string" || !data.cameraId ||
          data.cameraId.length > 256 || /[/\0]/.test(data.cameraId)) {
        response.status(400).json({error: "Nieprawidłowa kamera."});
        return;
      }
      let endpoint;
      try {
        endpoint = new URL(data.onvifServiceUrl);
      } catch (_) {
        endpoint = null;
      }
      const parts = (endpoint?.hostname || "").split(".").map(Number);
      const local = parts.length === 4 && parts.every((value) =>
        Number.isInteger(value) && value >= 0 && value <= 255) &&
        (parts[0] === 10 || (parts[0] === 192 && parts[1] === 168) ||
          (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31));
      if (!endpoint || !local || !identity(data.onvifDeviceId) ||
          !["http:", "https:"].includes(endpoint.protocol) ||
          endpoint.username || endpoint.password || endpoint.search ||
          endpoint.hash || endpoint.pathname.length > 256) {
        response.status(400).json({error: "Nieprawidłowy adres kamery."});
        return;
      }
      const reference = db.collection("users").doc(receiver.ownerId)
          .collection("cameras").doc(data.cameraId);
      const accepted = await db.runTransaction(async (transaction) => {
        const camera = (await transaction.get(reference)).data();
        if (!camera || camera.deletionPending ||
            camera.bridgeId !== receiver.bridgeId ||
            camera.monitoringMode !== "bridge" ||
            camera.connectionType !== "onvif" ||
            identity(camera.onvifDeviceId) !== identity(data.onvifDeviceId) ||
            camera.ipAddress !== data.previousIpAddress) return false;
        transaction.update(reference, {
          ipAddress: endpoint.hostname, onvifServiceUrl: endpoint.toString(),
          bridgeMonitoringStatus: "connecting",
          bridgeMonitoringUpdatedAt: Timestamp.now(),
          updatedAt: Timestamp.now(),
        });
        return true;
      });
      response.status(accepted ? 200 : 409).json({ok: accepted});
    } catch (_) {
      response.status(500).json({error: "Nie zapisano adresu kamery."});
    }
  };
}

module.exports = {createCameraEndpointRecoveryHandler};
