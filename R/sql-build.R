#' Build and render SQL from a sequence of lazy operations
#'
#' \code{sql_build} creates a \code{select_query} S3 object, that is rendered
#' to a SQL string by \code{sql_render}. The output from \code{sql_build} is
#' designed to be easy to test, as it's database diagnostic, and has
#' a hierarchical structure.
#'
#' \code{sql_build} is generic over the lazy operations, \link{lazy_ops},
#' and generates an S3 object that represents the query. \code{sql_render}
#' takes a query object and then calls a function that is generic
#' over the database. For example, \code{sql_build.op_mutate} generates
#' a \code{select_query}, and \code{sql_render.select_query} calls
#' \code{sql_select}, which has different methods for different databases.
#' The default methods should generate ANSI 92 SQL where possible, so you
#' backends only need to override the methods if the backend is not ANSI
#' compliant.
#'
#' @export
#' @keywords internal
#' @param op A sequence of lazy operations
#' @param con A database connection. The default \code{NULL} uses a set of
#'   rules that should be very similar to ANSI 92, and allows for testing
#'   without an active database connection.
#' @param ... Other arguments passed on to the methods. Not currently used.
sql_build <- function(op, con, ...) {
  UseMethod("sql_build")
}

#' @export
sql_build.tbl_sql <- function(op, con, ...) {
  sql_build(op$ops, op$con, ...)
}

#' @export
sql_build.tbl_lazy <- function(op, con = NULL, ...) {
  sql_build(op$ops, con, ...)
}

# Base ops --------------------------------------------------------

#' @export
sql_build.op_base_remote <- function(op, con, ...) {
  op$x
}

#' @export
sql_build.op_base_local <- function(op, con, ...) {
  ident("df")
}

# Single table ops --------------------------------------------------------

#' @export
sql_build.op_select <- function(op, con, ...) {
  vars <- select_vars_(op_vars(op$x), op$dots, include = op_grps(op$x))
  select_query(sql_build(op$x, con), ident(vars))
}

#' @export
sql_build.op_rename <- function(op, con, ...) {
  vars <- rename_vars_(op_vars(op$x), op$dots)
  select_query(sql_build(op$x, con), ident(vars))
}

#' @export
sql_build.op_arrange <- function(op, con, ...) {
  order_vars <- translate_sql_(op$dots, con, op_vars(op$x))
  group_vars <- c.sql(ident(op_grps(op$x)), con = con)

  select_query(sql_build(op$x, con), order_by = order_vars)
}

#' @export
sql_build.op_summarise <- function(op, con, ...) {
  select_vars <- translate_sql_(op$dots, con, op_vars(op$x), window = FALSE)
  group_vars <- c.sql(ident(op_grps(op$x)), con = con)

  select_query(
    sql_build(op$x, con),
    select = c.sql(group_vars, select_vars, con = con),
    group_by = group_vars
  )
}

#' @export
sql_build.op_mutate <- function(op, con, ...) {
  vars <- op_vars(op$x)

  new_vars <- translate_sql_(op$dots, con, vars,
    vars_group = op_grps(op),
    vars_order = op_sort(op)
  )
  old_vars <- ident(setdiff(vars, names(new_vars)))

  select_query(
    sql_build(op$x, con),
    select = c.sql(old_vars, new_vars, con = con)
  )
}


#' @export
sql_build.op_group_by <- function(op, con, ...) {
  sql_build(op$x, con, ...)
}

#' @export
sql_build.op_ungroup <- function(op, con, ...) {
  sql_build(op$x, con, ...)
}

#' @export
sql_build.op_filter <- function(op, con, ...) {
  vars <- op_vars(op$x)

  if (!uses_window_fun(op$dots, con)) {
    where_sql <- translate_sql_(op$dots, con, vars = vars)

    select_query(
      sql_build(op$x, con),
      where = where_sql
    )
  } else {
    # Do partial evaluation, then extract out window functions
    expr <- partial_eval2(op$dots, vars)
    where <- translate_window_where_all(expr, ls(sql_translate_env(con)$window))

    # Convert where$expr back to a lazy dots object, and then
    # create mutate operation
    mutate_dots <- lapply(where$comp, lazyeval::as.lazy)
    mutated <- sql_build(op_single("mutate", op$x, dots = mutate_dots), con)
    where_sql <- translate_sql_(where$expr, con = con, vars = vars)

    select_query(mutated, select = ident(vars), where = where_sql)
  }

}

#' @export
sql_build.op_distinct <- function(op, con, ...) {
  if (length(op$dots) > 0 && !op$args$.keep_all) {
    stop("Can't calculate distinct only on specified columns with SQL",
      call. = FALSE)
  }

  select_query(
    sql_build(op$x, con),
    distinct = TRUE
  )
}

# Dual table ops --------------------------------------------------------

#' @export
sql_build.op_join <- function(op, con, ...) {
  # Ensure tables have unique names
  x_names <- op_vars(op$x)
  y_names <- op_vars(op$y)
  by <- op$args$by

  uniques <- unique_names(x_names, y_names, by = by, suffix = op$args$suffix)

  if (is.null(uniques)) {
    x <- op$x
    y <- op$y
  } else {
    # TODO: it would be better to construct an explicit FROM statement
    # that used the table names to disambiguate the fields names: this
    # would remove a layer of subqueries and would make sql_join more
    # flexible.
    x <- select_(op$x, .dots = setNames(x_names, uniques$x))
    y <- select_(op$y, .dots = setNames(y_names, uniques$y))

    by$x <- unname(uniques$x[by$x])
    by$y <- unname(uniques$y[by$y])
  }

  join_query(x, y,
    type = op$args$type,
    by = by
  )
}

#' @export
sql_build.op_semi_join <- function(op, con, ...) {
  semi_join_query(op$x, op$y, anti = op$args$anti, by = op$args$by)
}

#' @export
sql_build.op_set_op <- function(op, con, ...) {
  set_op_query(op$x, op$y, type = op$args$type)
}
