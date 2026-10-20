import '../models/models.dart';
import '../slotter/slotter.dart';

abstract interface class PlanCalendar {
  Future<Map<String, String>> atomicRewrite(
    List<PlacementResult> placementResults,
    Map<String, String> existingDeviceIds,
  );
  Future<String> writeTaskEvent(Task task);
  Future<void> deleteEvent(String deviceEventId);
}
