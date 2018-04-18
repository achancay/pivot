#' Create a table with one row per pivot variable
#'
#' @param df A local dataframe or tbl_dbi database table
#' @param max_levels The maximum number of levels a pivot variable is allowed to have.
#'
#' @return A tibble with one row per pivot variable with the variable's name, number of levels, and a list column containing the levels.
#' @export
#' @import dplyr
#' @importFrom magrittr %>%
#' @examples
get_pivot_vars <- function(df, max_levels = 1000){
     df %>%
     summarise_all(n_distinct) %>%
     collect() %>%
     tidyr::gather("field", "n_levels") %>%
     filter(n_levels < max_levels) %>%
     mutate(levels = purrr::map(field, ~pull(distinct(select(df, .)))))
}


#' Generate the UI for a pivot table
#'
#' @param id The namespace id as a string. Can be anything but must match the corresponding namespace id of pivot_module.
#' @param pivot_vars A tibble created by get_pivot_vars()
#'
#' @return A tag list containing the UI elements for a pivot table module
#' @export
pivot_module_UI <- function(id, pivot_vars){
     ns <- NS(id)
     nsq <- function(.) glue::glue('"{ns(.)}"')

     tagList(
               tags$script(HTML(glue::glue('
                     $(document).ready(function() {{

                     const {id}_b = document.querySelectorAll("#{ns("source_vars")} div");
                     console.log("#{ns("source_vars")} div")
                     console.log({id}_b);
                     console.log("{id}_b.length is " + {id}_b.length)
                     var click_counter = 0;

                     function sendDataToShiny(clicked_button) {{
                          click_counter++;
                          var val = clicked_button.getAttribute("data-value");
                          //console.log("you clicked " + val + " and click_counter is " + click_counter);
                          Shiny.onInputChange({nsq("varname")}, val);
                          Shiny.onInputChange({nsq("click_counter")}, click_counter);
                     }}

                     for (var i = 0; i < {id}_b.length; i++) {{
                          {id}_b[i].addEventListener("click", function(){{
                              //console.log("you clicked " + this.getAttribute("data-value"));
                              sendDataToShiny(this);

                         }}, false);
                     }}

                     Shiny.addCustomMessageHandler("{id}_shade", function (val) {{
                         //console.log("recieved " + val)
                          for (var i = 0; i < {id}_b.length; i++) {{
                               if (val == {id}_b[i].getAttribute("data-value")){{
                                    {id}_b[i].style.backgroundColor = "#b6b8ba";
                               }}
                          }}
                     }});

                     Shiny.addCustomMessageHandler("{id}_unshade", function (val) {{
                          for (var i = 0, len = {id}_b.length; i < len; i++) {{
                               if (val == {id}_b[i].getAttribute("data-value")){{
                                    {id}_b[i].style.backgroundColor = "#ffffff";
                               }}
                          }}
                     }});

                    }});'))),

                # fluidRow(column(4, verbatimTextOutput(ns("debug_text")))),
                fluidRow(column(4, tags$div(style = "color: red", textOutput(ns("warn_text"))))),
                fluidRow(column(12, wellPanel(
                     shinyjqui::orderInput(ns("source_vars"), "Variables", items = pivot_vars$field, connect = c(ns("row_vars"), ns("col_vars")))
                ))),
                fluidRow(
                     column(3, downloadButton(ns("download_data"))),
                     column(9, wellPanel(shinyjqui::orderInput(ns("col_vars"), "Columns", items = NULL, placeholder = "Drag variables here", connect = c(ns("source_vars"), ns("row_vars")))))
                ),
                fluidRow(
                     column(3, wellPanel(shinyjqui::orderInput(ns("row_vars"), "Rows", items = NULL, placeholder = "Drag variables here", connect = c(ns("source_vars"), ns("col_vars"))))),
                     column(9, tags$div(style = "overflow:auto", dataTableOutput(ns("table"))))
                )
     )
}

#' The server function for a pivot table module
#'
#' This function should be passed to callModule. See example.
#'
#' @param input A standard argument used by shiny when creating the module.
#' @param output A standard argument used by shiny when creating the module.
#' @param session A standard argument used by shiny when creating the module.
#' @param ns_id The module namespace id as a string. Must match a namespace id of the corresponding UI module element.
#' @param df A local dataframe/tibble or tbl_dbi database connection object.
#' @param pivot_vars A table constructed using the get_pivot_vars function.
#' @param record_limit The maximum number of rows to bring into R to display. This is a saftely measure. You probably don't want to bring 100 million rows of data into R from a database. Defaults to 1 million.
#'
#' @return The server function needed for a pivot table module.
#' @export
#'
#' @examples
#'  # note that the namespace id must
#' server <- function(input, output, session){
#'    callModule(pivot_module, id = "id1", ns_id = "id1", df = df1, pivot_vars = pivot_vars1, record_limit = 20)
#' }
#'
pivot_module <- function(input, output, session, ns_id, df, pivot_vars, record_limit = 1e6){
     ns <- NS(ns_id)
     # add reactive values to the pivot vars tibble in a list column.
     # One select input and one T/F filtered indicator per pivot variable.
     # Need to add namespace to any newly created input ids. Use ns() when defining new input id
     pivot_vars <- pivot_vars %>%
          mutate(select_input = purrr::map2(field, levels,
               ~reactive(selectInput(ns(.x), label = .x, choices = c("All levels" = "", .y), selected = input[[.x]], multiple = T)))) %>%
          mutate(filtered = purrr::map(field, ~reactive({length(input[[.x]]) > 0})))

     # print(pivot_vars)
     # which variable was clicked? (represented as a number from 1 to number of pivot vars)
     varnum <- reactive(match(input$varname, pivot_vars$field))

     # # open dialog box when clicked
     observeEvent(input$click_counter, {
          showModal(modalDialog(easyClose = T, title = "Filter", pivot_vars$select_input[[varnum()]]()))
     })


     filter_expr <- reactive({
          # T/F indicators to select rows of filtered variables
          selector <- purrr::map_lgl(pivot_vars$filtered, ~.())

          # initially no variables will be filtered
          if(all(!selector)) return(NULL)

          exp_builder <- pivot_vars %>%
               filter(selector) %>%
               mutate(selected_levels = purrr::map(field, ~input[[.]])) %>%
               mutate(selected_levels = purrr::map(selected_levels, ~paste(.))) %>%
               select(field, selected_levels)

          purrr::map2(exp_builder$field, exp_builder$selected_levels, ~rlang::expr(!!as.name(.x) %in% !!.y)) %>%
               purrr::reduce(function(a,b) rlang::expr(!!a & !!b))
     })

     # maybe use event reactive and update button
     filtered_data <- reactive({
          grp_vars <- rlang::parse_quosures(paste0(c(input$row_vars_order, input$col_vars_order), collapse = ";"))
          df %>%
               {if(!is.null(filter_expr)) filter(., !!!filter_expr()) else .} %>% # conditional pipe
               group_by(!!!grp_vars) %>%
               summarise(n = n()) %>%
               ungroup()
     })



     # also need to add warning for exceeding row limit
     local_table <- reactive({
          filtered_data() %>%
               head(record_limit) %>%
               # filter(between(row_number(), 1, record_limit)) %>%
               collect() %>%
               mutate_if(~class(.) == "integer64", as.numeric) %>%
               {
                    if(length(input$col_vars_order) > 0 ){
                         tidyr::unite(., "col_var", input$col_vars_order, sep = "_&_") %>%
                              tidyr::spread(col_var, n, fill = 0)
                    } else .
               }
     })


     # update button colors based on filtering
     observe({
          for (i in 1:nrow(pivot_vars)) {
               if(pivot_vars$filtered[[i]]() == TRUE){
                    # print(paste("sending ", pivot_vars$field[i]))
                    session$sendCustomMessage(type = paste0(ns_id, "_shade"), pivot_vars$field[i])
               } else {
                    session$sendCustomMessage(type = paste0(ns_id, "_unshade"), pivot_vars$field[i])
               }
          }
     })

     output$warn_text <- renderText({
          if(nrow(local_table()) == record_limit){
               return(glue::glue("Warning: Only showing first {record_limit} rows."))
          } else return(NULL)
     })

     output$table <- renderDataTable(local_table())
     output$debug_text <- renderPrint(NULL)
     output$download_data <- downloadHandler(
          filename = function() paste0("data_", Sys.Date(), ".csv"),
          content = function(file) readr::write_csv(local_table(), file),
          contentType = "text/csv"
     )
} # end server










