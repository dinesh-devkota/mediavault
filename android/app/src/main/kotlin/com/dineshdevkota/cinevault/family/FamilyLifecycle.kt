package com.dineshdevkota.cinevault.family

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.view.WindowManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Counts started activities so navigation within MediaVault does not end a household session. */
class FamilyLifecycle(private val family: FamilyStore, scope: CoroutineScope, private val onLock: () -> Unit) : Application.ActivityLifecycleCallbacks {
    private var started = 0
    private val activities = mutableSetOf<Activity>()
    init {
        scope.launch(Dispatchers.Main.immediate) {
            family.session.collect { session -> activities.forEach { protect(it, session.enabled) } }
        }
    }
    private fun protect(activity: Activity, enabled: Boolean) {
        if (enabled) activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    override fun onActivityCreated(activity: Activity, state: Bundle?) {
        // Recents screenshots must not retain a protected title or photo after a session locks.
        activities += activity
        protect(activity, family.current.enabled)
    }
    override fun onActivityStarted(activity: Activity) { started++ }
    override fun onActivityStopped(activity: Activity) {
        started = (started - 1).coerceAtLeast(0)
        if (started == 0 && !activity.isChangingConfigurations) { family.lock(); onLock() }
    }
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) { activities -= activity }
}
