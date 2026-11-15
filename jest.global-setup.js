// A zone with clock changes, so tests of day counting meet 23- and 25-hour days. Set here because
// a test file cannot change the zone of its own process.
module.exports = () => {
  process.env.TZ = 'America/New_York';
};
