/**
 * @description Queueable wrapper for CMLGenerator to handle session ID issues
 * This runs in a system context where UserInfo.getSessionId() returns a valid API session ID
 */
public class CMLGeneratorQueueable implements Queueable, Database.AllowsCallouts {
    
    /**
     * @description Execute method for Queueable
     * @param context The QueueableContext
     */
    public void execute(QueueableContext context) {
        try {
            System.debug('=== CMLGeneratorQueueable Started ===');
            String result = CMLGeneratorV2.execute();
            System.debug('=== CMLGeneratorQueueable Completed ===');
            System.debug('Result: ' + result);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CMLGeneratorQueueable Error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack Trace: ' + e.getStackTraceString());
            throw e;
        }
    }
    
    /**
     * @description Static method to enqueue the job
     * @return Id The job ID
     */
    public static Id enqueue() {
        return System.enqueueJob(new CMLGeneratorQueueable());
    }
}
