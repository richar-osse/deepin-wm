//
//  Copyright (C) 2012 Tom Beckmann, Rico Tzschichholz
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Clutter;
using Meta;

namespace Gala
{
	public class WindowSwitcher : Clutter.Actor
	{
		const int MIN_DELTA = 100;

		public WindowManager wm { get; construct; }

		Utils.WindowIcon? current_window = null;

		Actor window_clones;
		List<Actor> clone_sort_order;

		WindowActor? dock_window;
		Actor dock;
		Plank.Drawing.DockSurface? dock_surface;
		Plank.Drawing.DockTheme dock_theme;
		Plank.DockPreferences dock_settings;
		float dock_y_offset;
		float dock_height_offset;
		FileMonitor monitor;

		uint modifier_mask;
		int64 last_switch = 0;
		bool closing = false;
		ModalProxy modal_proxy;

		// estimated value, if possible
		float dock_width = 0.0f;
		int n_dock_items = 0;

		public WindowSwitcher (WindowManager wm)
		{
			Object (wm: wm);
		}

		construct
		{
			// pull drawing methods from libplank
			var settings_file = Environment.get_user_config_dir () + "/plank/dock1/settings";
			dock_settings = new Plank.DockPreferences.with_filename (settings_file);
			dock_settings.notify.connect (update_dock);
			dock_settings.notify["Theme"].connect (load_dock_theme);

			var launcher_folder = Plank.Services.Paths.AppConfigFolder.get_child ("dock1").get_child ("launchers");

			if (launcher_folder.query_exists ()) {
				try {
					monitor = launcher_folder.monitor (FileMonitorFlags.NONE);
					monitor.changed.connect (update_n_dock_items);
				} catch (Error e) { warning (e.message); }

				// initial update, pretend a file was created
				update_n_dock_items (launcher_folder, null, FileMonitorEvent.CREATED);
			}

			dock = new Actor ();
			dock.layout_manager = new BoxLayout ();

			var dock_canvas = new Canvas ();
			dock_canvas.draw.connect (draw_dock_background);

			dock.content = dock_canvas;
			dock.actor_removed.connect (icon_removed);
			dock.notify["allocation"].connect (() =>
				dock_canvas.set_size ((int) dock.width, (int) dock.height));

			load_dock_theme ();

			window_clones = new Actor ();
			window_clones.actor_removed.connect (window_removed);

			add_child (window_clones);
			add_child (dock);

			wm.get_screen ().monitors_changed.connect (update_dock);

			visible = false;
		}

		~WindowSwitcher ()
		{
			if (monitor != null)
				monitor.cancel ();

			wm.get_screen ().monitors_changed.disconnect (update_dock);
		}

		void load_dock_theme ()
		{
			if (dock_theme != null)
				dock_theme.notify.disconnect (update_dock);

			dock_theme = new Plank.Drawing.DockTheme (dock_settings.Theme);
			dock_theme.load ("dock");
			dock_theme.notify.connect (update_dock);

			update_dock ();
		}

		/**
		 * set the values which don't get set every time and need to be updated when the theme changes
		 */
		void update_dock ()
		{
			var screen = wm.get_screen ();
			var geometry = screen.get_monitor_geometry (screen.get_primary_monitor ());
			var layout = (BoxLayout) dock.layout_manager;

			var position = dock_settings.Position;
			var icon_size = dock_settings.IconSize;
			var scaled_icon_size = icon_size / 10.0f;
			var horizontal = dock_settings.is_horizontal_dock ();

			var top_padding = (float) dock_theme.TopPadding * scaled_icon_size;
			var bottom_padding = (float) dock_theme.BottomPadding * scaled_icon_size;
			var item_padding = (float) dock_theme.ItemPadding * scaled_icon_size;
			var line_width = dock_theme.LineWidth;

			var top_offset = 2 * line_width + top_padding;
			var bottom_offset = (dock_theme.BottomRoundness > 0 ? 2 * line_width : 0) + bottom_padding;

			layout.spacing = (uint) item_padding;
			layout.orientation = horizontal ? Orientation.HORIZONTAL : Orientation.VERTICAL;

			dock_y_offset = -top_offset;
			dock_height_offset = top_offset + bottom_offset;

			var height = icon_size + (top_offset > 0 ? top_offset : 0) + bottom_offset;

			dock.anchor_gravity = horizontal ? Gravity.NORTH : Gravity.WEST;

			if (horizontal) {
				dock.height = height;
				dock.x = Math.ceilf (geometry.x + geometry.width / 2.0f);
			} else {
				dock.width = height;
				dock.y = Math.ceilf (geometry.y + geometry.height / 2.0f);
			}

			switch (position) {
				case Gtk.PositionType.TOP:
					dock.y = Math.ceilf (geometry.y);
					break;
				case Gtk.PositionType.BOTTOM:
					dock.y = Math.ceilf (geometry.y + geometry.height - height);
					break;
				case Gtk.PositionType.LEFT:
					dock.x = Math.ceilf (geometry.x);
					break;
				case Gtk.PositionType.RIGHT:
					dock.x = Math.ceilf (geometry.x + geometry.width - height);
					break;
			}

			dock_surface = null;
		}

		bool draw_dock_background (Cairo.Context cr)
		{
			cr.set_operator (Cairo.Operator.CLEAR);
			cr.paint ();
			cr.set_operator (Cairo.Operator.OVER);

			var position = dock_settings.Position;

			var width = (int) dock.width;
			var height = (int) dock.height;

			switch (position) {
				case Gtk.PositionType.RIGHT:
					width += (int) dock_height_offset;
					break;
				case Gtk.PositionType.LEFT:
					width -= (int) dock_y_offset;
					break;
				case Gtk.PositionType.TOP:
					height -= (int) dock_y_offset;
					break;
				case Gtk.PositionType.BOTTOM:
					height += (int) dock_height_offset;
					break;
			}

			if (dock_surface == null || dock_surface.Width != width || dock_surface.Height != height) {
				var dummy_surface = new Plank.Drawing.DockSurface.with_surface (1, 1, cr.get_target ());

				dock_surface = dock_theme.create_background (width, height, position, dummy_surface);
			}

			float x = 0, y = 0;
			switch (position) {
				case Gtk.PositionType.RIGHT:
					x = dock_y_offset;
					break;
				case Gtk.PositionType.BOTTOM:
					y = dock_y_offset;
					break;
				case Gtk.PositionType.LEFT:
					x = 0;
					break;
				case Gtk.PositionType.TOP:
					y = 0;
					break;
			}

			cr.set_source_surface (dock_surface.Internal, x, y);
			cr.paint ();

			return false;
		}

		void place_dock ()
		{
			var icon_size = dock_settings.IconSize;
			var scaled_icon_size = icon_size / 10.0f;
			var line_width = dock_theme.LineWidth;
			var horiz_padding = dock_theme.HorizPadding * scaled_icon_size;
			var item_padding = (float) dock_theme.ItemPadding * scaled_icon_size;
			var items_offset = (int) (2 * line_width + (horiz_padding > 0 ? horiz_padding : 0));

			if (n_dock_items > 0)
				dock_width = n_dock_items * (item_padding + icon_size) + items_offset * 2;
			else
				dock_width = (dock_window != null ? dock_window.width : 300.0f);

			if (dock_settings.is_horizontal_dock ()) {
				dock.width = dock_width;
				dock.get_first_child ().margin_left = items_offset;
				dock.get_last_child ().margin_right = items_offset;
			} else {
				dock.height = dock_width;
				dock.get_first_child ().margin_top = items_offset;
				dock.get_last_child ().margin_bottom = items_offset;
			}

			dock.opacity = 255;
		}

		void animate_dock_width ()
		{
			dock.save_easing_state ();
			dock.set_easing_duration (250);
			dock.set_easing_mode (AnimationMode.EASE_OUT_CUBIC);

			float dest_width;
			if (dock_settings.is_horizontal_dock ()) {
				dock.layout_manager.get_preferred_width (dock, dock.height, null, out dest_width);
				dock.width = dest_width;
			} else {
				dock.layout_manager.get_preferred_height (dock, dock.width, null, out dest_width);
				dock.height = dest_width;
			}

			dock.restore_easing_state ();
		}

		bool clicked_icon (Clutter.ButtonEvent event) {
			unowned Utils.WindowIcon icon = (Utils.WindowIcon) event.source;

			if (current_window != icon) {
				current_window = icon;
				dim_windows ();

				// wait for the dimming to finish
				Timeout.add (250, () => {
					close (wm.get_screen ().get_display ().get_current_time ());
					return false;
				});
			} else
				close (event.time);

			return true;
		}

		void window_removed (Actor actor)
		{
			clone_sort_order.remove (actor);
		}

		void icon_removed (Actor actor)
		{
			if (dock.get_n_children () == 1) {
				close (wm.get_screen ().get_display ().get_current_time ());
				return;
			}

			if (actor == current_window) {
				current_window = (Utils.WindowIcon) current_window.get_next_sibling ();
				if (current_window == null)
					current_window = (Utils.WindowIcon) dock.get_first_child ();

				dim_windows ();
			}

			animate_dock_width ();
		}

		public override bool key_release_event (Clutter.KeyEvent event)
		{
			if ((get_current_modifiers () & modifier_mask) == 0)
				close (event.time);

			return true;
		}

		public override void key_focus_out ()
		{
			close (wm.get_screen ().get_display ().get_current_time ());
		}

		public void handle_switch_windows (Display display, Screen screen, Window? window,
#if HAS_MUTTER314
			Clutter.KeyEvent event, KeyBinding binding)
#else
			X.Event event, KeyBinding binding)
#endif
		{
			var now = get_monotonic_time () / 1000;
			if (now - last_switch < MIN_DELTA)
				return;

			last_switch = now;

			var workspace = screen.get_active_workspace ();
			var binding_name = binding.get_name ();
			var backward = binding_name.has_suffix ("-backward");

			// FIXME for unknown reasons, switch-applications-backward won't be emitted, so we
			//       test manually if shift is held down
			backward = binding_name == "switch-applications"
				&& (get_current_modifiers () & ModifierType.SHIFT_MASK) != 0;

			if (visible && !closing) {
				current_window = next_window (workspace, backward);
				dim_windows ();
				return;
			}

			if (!collect_windows (workspace))
				return;

			set_primary_modifier (binding.get_mask ());

			current_window = next_window (workspace, backward);

			place_dock ();

			visible = true;
			closing = false;
			wm.block_keybindings_in_modal = false;
			modal_proxy = wm.push_modal ();

			animate_dock_width ();

			dim_windows ();
			grab_key_focus ();

			if ((get_current_modifiers () & modifier_mask) == 0)
				close (wm.get_screen ().get_display ().get_current_time ());
		}

		void close (uint time)
		{
			if (closing)
				return;

			closing = true;
			last_switch = 0;

			var screen = wm.get_screen ();
			var workspace = screen.get_active_workspace ();

			foreach (var actor in clone_sort_order) {
				unowned InternalUtils.SafeWindowClone clone = (InternalUtils.SafeWindowClone) actor;

				// current window stays on top
				if (clone.window == current_window.window)
					continue;

				// reset order
				window_clones.set_child_below_sibling (clone, null);

				if (!clone.window.minimized) {
					clone.save_easing_state ();
					clone.set_easing_duration (150);
					clone.set_easing_mode (AnimationMode.EASE_OUT_CUBIC);
					clone.z_position = 0;
					clone.opacity = 255;
					clone.restore_easing_state ();
				}
			}

			if (current_window != null) {
				current_window.window.activate (time);
				current_window = null;
			}

			wm.pop_modal (modal_proxy);

			if (dock_window != null)
				dock_window.opacity = 0;

			var dest_width = (dock_width > 0 ? dock_width : 600.0f);

			set_child_above_sibling (dock, null);

			if (dock_window != null) {
				dock_window.show ();
				dock_window.save_easing_state ();
				dock_window.set_easing_mode (AnimationMode.LINEAR);
				dock_window.set_easing_duration (250);
				dock_window.opacity = 255;
				dock_window.restore_easing_state ();
			}

			dock.save_easing_state ();
			dock.set_easing_duration (250);
			dock.set_easing_mode (AnimationMode.EASE_OUT_CUBIC);

			if (dock_settings.is_horizontal_dock ())
				dock.width = dest_width;
			else
				dock.height = dest_width;

			dock.opacity = 0;
			dock.restore_easing_state ();

			Clutter.Callback cleanup = () => {
				dock.destroy_all_children ();

				dock_window = null;
				visible = false;

				window_clones.destroy_all_children ();

				// need to go through all the windows because of hidden dialogs
				unowned List<WindowActor>? window_actors = Compositor.get_window_actors (screen);
				foreach (var actor in window_actors) {
					unowned Window window = actor.get_meta_window ();

					if (window.get_workspace () == workspace
						&& window.showing_on_its_workspace ())
						actor.show ();
				}
			};

			var transition = dock.get_transition ("opacity");
			if (transition != null)
				transition.completed.connect (() => cleanup (this));
			else
				cleanup (this);
		}

		Utils.WindowIcon? add_window (Window window)
		{
			var actor = window.get_compositor_private () as WindowActor;
			if (actor == null)
				return null;

			actor.hide ();

			var clone = new InternalUtils.SafeWindowClone (window, true);
			clone.x = actor.x;
			clone.y = actor.y;

			window_clones.add_child (clone);

			var icon = new Utils.WindowIcon (window, dock_settings.IconSize, true);
			icon.reactive = true;
			icon.opacity = 100;
			icon.x_expand = true;
			icon.y_expand = true;
			icon.x_align = ActorAlign.CENTER;
			icon.y_align = ActorAlign.CENTER;
			icon.button_release_event.connect (clicked_icon);

			dock.add_child (icon);

			return icon;
		}

		void dim_windows ()
		{
			var window_opacity = (int) Math.floor (AppearanceSettings.get_default ().alt_tab_window_opacity * 255);

			foreach (var actor in window_clones.get_children ()) {
				unowned InternalUtils.SafeWindowClone clone = (InternalUtils.SafeWindowClone) actor;

				actor.save_easing_state ();
				actor.set_easing_duration (250);
				actor.set_easing_mode (AnimationMode.EASE_OUT_QUAD);

				if (clone.window == current_window.window) {
					window_clones.set_child_above_sibling (actor, null);
					actor.z_position = 0;
					actor.opacity = 255;
				} else {
					actor.z_position = -200;
					actor.opacity = window_opacity;
				}

				actor.restore_easing_state ();
			}

			foreach (var actor in dock.get_children ()) {
				unowned Utils.WindowIcon icon = (Utils.WindowIcon) actor;
				icon.save_easing_state ();
				icon.set_easing_duration (100);
				icon.set_easing_mode (AnimationMode.LINEAR);

				if (icon == current_window)
					icon.opacity = 255;
				else
					icon.opacity = 100;

				icon.restore_easing_state ();
			}
		}

		/**
		 * Adds the suitable windows on the given workspace to the switcher
		 *
		 * @return whether the switcher should actually be started or if there are
		 *         not enough windows
		 */
		bool collect_windows (Workspace workspace)
		{
			var screen = workspace.get_screen ();
			var display = screen.get_display ();

#if HAS_MUTTER314
			var windows = display.get_tab_list (TabList.NORMAL, workspace);
			var current = display.get_tab_current (TabList.NORMAL, workspace);
#else
			var windows = display.get_tab_list (TabList.NORMAL, screen, workspace);
			var current = display.get_tab_current (TabList.NORMAL, screen, workspace);
#endif

			if (windows.length () < 1)
				return false;

			if (windows.length () == 1) {
				var window = windows.data;
				if (window.minimized)
					window.unminimize ();
				else
					Utils.bell (screen);

				window.activate (display.get_current_time ());

				return false;
			}

			foreach (var window in windows) {
				var clone = add_window (window);
				if (window == current)
					current_window = clone;
			}

			clone_sort_order = window_clones.get_children ().copy ();

			if (current_window == null)
				current_window = (Utils.WindowIcon) dock.get_child_at_index (0);

			// hide the others
			foreach (var actor in Compositor.get_window_actors (screen)) {
				var window = actor.get_meta_window ();
				var type = window.window_type;

				if (type != WindowType.DOCK
					&& type != WindowType.DESKTOP
					&& type != WindowType.NOTIFICATION)
					actor.hide ();

				if (window.title in BehaviorSettings.get_default ().dock_names
					&& type == WindowType.DOCK) {
					dock_window = actor;
					dock_window.hide ();
				}
			}

			return true;
		}

		Utils.WindowIcon next_window (Workspace workspace, bool backward)
		{
			Actor actor;
			if (!backward) {
				actor = current_window.get_next_sibling ();
				if (actor == null)
					actor = dock.get_first_child ();
			} else {
				actor = current_window.get_previous_sibling ();
				if (actor == null)
					actor = dock.get_last_child ();
			}

			return (Utils.WindowIcon) actor;
		}

		/**
		 * copied from gnome-shell, finds the primary modifier in the mask and saves it
		 * to our modifier_mask field
		 *
		 * @param mask The modifier mask to extract the primary one from
		 */
		void set_primary_modifier (uint mask)
		{
			if (mask == 0)
				modifier_mask = 0;
			else {
				modifier_mask = 1;
				while (mask > 1) {
					mask >>= 1;
					modifier_mask <<= 1;
				}
			}
		}

		/**
		 * Counts the launcher items to get an estimate of the window size
		 */
		void update_n_dock_items (File folder, File? other_file, FileMonitorEvent event)
		{
			if (event != FileMonitorEvent.CREATED && event != FileMonitorEvent.DELETED)
				return;

			var count = 0;

			try {
				var children = folder.enumerate_children ("", 0);
				while (children.next_file () != null)
					count++;

			} catch (Error e) { warning (e.message); }

			n_dock_items = count;
		}

		Gdk.ModifierType get_current_modifiers ()
		{
			Gdk.ModifierType modifiers;
			double[] axes = {};
			Gdk.Display.get_default ().get_device_manager ().get_client_pointer ()
				.get_state (Gdk.get_default_root_window (), axes, out modifiers);

			return modifiers;
		}
	}
}
