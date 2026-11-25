package sh.naive.android

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import sh.naive.android.core.AppModel
import sh.naive.android.core.Fonts
import sh.naive.android.design.LocalAssets

class NaiveApplication : Application() {
    lateinit var model: AppModel
        private set

    override fun onCreate() {
        super.onCreate()
        LocalAssets.manager = assets
        Fonts.init(assets)
        model = AppModel(this)
        // Once per process (activities come and go with configuration changes).
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = model.onForeground()
            override fun onStop(owner: LifecycleOwner) = model.onBackground()
        })
    }
}
