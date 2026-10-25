class RoomError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function requireAction(condition, code, message) {
  if (!condition) throw new RoomError(code, message);
}

module.exports = { RoomError, requireAction };
